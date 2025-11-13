const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("helpers");
const ZonType = helpers.buildInfo.ZonType;
const zon = @import("zon");
const zonParse = helpers.parseZon;
const inherit = helpers.inherit;

pub const CppPropsJson = struct {
    version: usize,
    configurations: []Configuration,

    pub const Configuration = struct {
        name: []const u8,
        includePath: [][]const u8,
        browse: Browse,
        defines: [][]const u8,
        cppStandard: []const u8,
        compilerPath: []const u8,
        compilerArgs: [][]const u8,

        const Browse = struct {
            limitSymbolsToIncludedHeaders: bool,
            path: [][]const u8,
        };
    };
};

pub fn getFileContents(
    dir: std.fs.Dir,
    name: []const u8,
    alloc: std.mem.Allocator,
    maxLen: usize,
) ![]const u8 {
    var buf = try alloc.alloc(u8, maxLen);
    errdefer alloc.free(buf);
    const file = try dir.openFile(name, .{});
    var reader = file.reader(&.{});
    const len = try reader.interface.readSliceShort(buf);
    if (len < buf.len) {
        if (alloc.resize(buf, len)) {
            buf = buf[0..len];
        } else {
            const newBuf = try alloc.alloc(u8, buf.len);
            @memcpy(newBuf, buf[0..len]);
            alloc.free(buf);
            buf = newBuf;
        }
    }
    return buf;
}

const DependencyInfo = struct {
    name: []const u8,
    location: union(enum) {
        url: []const u8,
        path: []const u8,
    },
};
pub fn getTheseDeps(
    allocator: std.mem.Allocator,
    val: ZonType,
    mode: []const u8,
) ![]DependencyInfo {
    var deps: std.ArrayList(DependencyInfo) = .{};

    const next = val.get(mode);

    // for all actual dependencies it uses...
    for (next.dependencies) |dep| {
        for (deps.items) |currentDep| {
            if (std.mem.eql(u8, currentDep.name, dep.dependencyName)) {
                break;
            }
        } else {
            // if we have not yet encountered that dependency...
            const newDep: DependencyInfo = blk: {
                // find the dependency we want...
                inline for (@typeInfo(@TypeOf(zon.dependencies)).@"struct".fields) |f| {
                    if (std.mem.eql(u8, f.name, dep.dependencyName)) {
                        const field = @field(zon.dependencies, f.name);
                        // create a dependency object
                        break :blk .{
                            .name = f.name,
                            .location = if (@hasField(@TypeOf(field), "url"))
                                .{ .url = field.url }
                            else
                                .{ .path = field.path },
                        };
                    }
                }
                @panic("No dependency found!");
            };
            // append the dependency to the array
            try deps.append(allocator, newDep);
        }
    }
    return deps.items;
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    var zonParseArena: std.heap.ArenaAllocator = .init(allocator);
    const arena = zonParseArena.allocator();

    var val = zonParse.parseZonStruct(
        arena,
        ZonType,
        zon.buildmodes,
        ".buildmodes",
    );

    try inherit.resolveInheritance(arena, &val);

    var argIterator = try std.process.argsWithAllocator(arena);
    if (argIterator.next()) |_| {} else {
        return error.NoArgs;
    }

    const pioProgramName = argIterator.next() orelse "platformio";
    _ = pioProgramName;
    const mode = argIterator.next() orelse "desktop";
    const pythonInc = argIterator.next() orelse "desktop";
    const depHeaders = argIterator.next() orelse "desktop";
    const compatHeaders = argIterator.next() orelse "platformio_clangd";
    _ = compatHeaders;
    const cwd = try std.process.getCwdAlloc(arena);
    const compileFlags = argIterator.next() orelse
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ cwd, "zig-out/ogaboogaflags.txt" });
    // const cCppProps = argIterator.next() orelse
    //     try std.fmt.allocPrint(
    //         arena,
    //         "{s}/{s}",
    //         .{ cwd, "./zig-out/.vscode/c_cpp_properties.json" },
    //     );
    // const currentCppProps = argIterator.next() orelse
    //     try std.fmt.allocPrint(
    //         arena,
    //         "{s}/{s}",
    //         .{ cwd, "./.vscode/c_cpp_properties.json" },
    //     );

    const modeInfo = val.get(mode);

    var soBuf: [512]u8 = undefined;
    var soWriter = std.fs.File.stdout().writer(&soBuf);
    const stdout = &soWriter.interface;

    const deps = try getTheseDeps(allocator, val, mode);

    var fileBuf: [512]u8 = undefined;
    {
        const cFlagsFile = try std.fs.createFileAbsolute(compileFlags, .{ .truncate = true });
        defer cFlagsFile.close();
        var compileFlagsWriter = cFlagsFile.writer(&fileBuf);
        const cflagsiow = &compileFlagsWriter.interface;

        try cflagsiow.writeAll("-xc++\n");

        // have to be able to access the actual code
        try cflagsiow.writeAll("-Isrc\n");

        if (std.mem.containsAtLeastScalar(
            helpers.buildInfo.BuildInfo.OutputType,
            modeInfo.outputTypes,
            1,
            .pythonmodule,
        )) {
            try cflagsiow.print("-I{s}\n", .{pythonInc});
        }
        for (deps) |dep| {
            switch (dep.location) {
                .path => |p| {
                    try cflagsiow.print("-I{s}/src\n", .{p});
                },
                .url => |_| {},
            }
        }

        try cflagsiow.print("-Izig-out/include/{s}\n", .{depHeaders});

        for (modeInfo.cpp.otherFlags) |flag| {
            try cflagsiow.print("{s}\n", .{flag});
        }

        for (modeInfo.cpp.include) |inc| {
            try cflagsiow.print("-I{s}\n", .{inc});
        }

        for (modeInfo.cpp.linkPath) |inc| {
            try cflagsiow.print("-L{s}\n", .{inc});
        }

        if (modeInfo.cpp.define) |d| {
            var iter = d.map.iterator();

            while (iter.next()) |v| {
                if (v.value_ptr.*) |valueStr| {
                    try cflagsiow.print("-D{s}", .{v.key_ptr.*});

                    if (valueStr.len != 0) {
                        try cflagsiow.print("={s}", .{valueStr});
                    }
                    try cflagsiow.writeAll("\n");
                }
            }
        }
        try cflagsiow.flush();
    }

    // if (addToJson(
    //     arena,
    //     modeInfo,
    //     currentCppProps,
    //     cCppProps,
    //     pythonInc,
    //     mode,
    //     &fileBuf,
    // )) {} else |_| {
    //     std.debug.print("Creating ykyk\n", .{});
    //     const includePathLen = 1 + 1 + modeInfo.cpp.include.len;
    //
    //     const include = try arena.alloc([]const u8, includePathLen);
    //     include[0] = "src";
    //     include[1] = pythonInc;
    //
    //     @memcpy(include[2..], modeInfo.cpp.include);
    //
    //     const cppstd = blk: {
    //         for (modeInfo.cpp.otherFlags) |f| {
    //             const stdflag = "-std=";
    //             if (std.mem.startsWith(u8, f, stdflag)) {
    //                 break :blk f[stdflag.len..];
    //             }
    //         }
    //         break :blk "c++11";
    //     };
    //
    //     var defines: std.ArrayList([]const u8) = .{};
    //     defer defines.deinit(arena);
    //
    //     if (modeInfo.cpp.define) |d| {
    //         var iter = d.map.iterator();
    //
    //         while (iter.next()) |k| {
    //             if (k.value_ptr.*) |value| {
    //                 if (value.len == 0) {
    //                     try defines.append(arena, k.key_ptr.*);
    //                 } else {
    //                     try defines.append(
    //                         arena,
    //                         try std.fmt.allocPrint(
    //                             arena,
    //                             "{s}={s}",
    //                             .{ k.key_ptr.*, value },
    //                         ),
    //                     );
    //                 }
    //             }
    //         }
    //     }
    //
    //     const config: CppPropsJson.Configuration = .{
    //         .name = mode,
    //         .includePath = include,
    //         .defines = defines.items,
    //         .cppStandard = cppstd,
    //         .compilerArgs = modeInfo.cpp.otherFlags,
    //         .compilerPath = "clang",
    //         .browse = .{
    //             .limitSymbolsToIncludedHeaders = false,
    //             .path = include,
    //         },
    //     };
    //
    //     var value: CppPropsJson = undefined;
    //
    //     var configBuf: [1]CppPropsJson.Configuration = .{config};
    //     value.configurations = &configBuf;
    //     value.version = 4;
    //
    //     const cppPropsFile = try std.fs.createFileAbsolute(cCppProps, .{ .truncate = true });
    //     defer cppPropsFile.close();
    //     var cppPropsWriter = cppPropsFile.writer(&fileBuf);
    //     const cpppropsiow = &cppPropsWriter.interface;
    //
    //     try std.json.fmt(value, .{}).format(cpppropsiow);
    //
    //     try cpppropsiow.flush();
    // }

    try stdout.flush();
}

fn isAsciiSpace(char: u8) bool {
    return char <= ' ' and char > 0;
}

const runProcess = if (builtin.zig_version.minor >= 12) std.process.Child.run else std.process.Child.exec;
