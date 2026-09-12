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
    var deps: std.ArrayList(DependencyInfo) = .empty;

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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // const allocator = init.gpa;
    const arena = init.arena.allocator();
    defer _ = init.arena.reset(.free_all);

    var val = zonParse.parseZonStruct(
        arena,
        ZonType,
        zon.buildmodes,
        ".buildmodes",
    );

    try inherit.resolveInheritance(arena, &val);

    var argIterator = try init.minimal.args.iterateAllocator(arena);
    if (argIterator.next()) |_| {} else {
        return error.NoArgs;
    }

    const projectName = argIterator.next() orelse "idkprogramname :((";
    const pioProgramName = argIterator.next() orelse "platformio";
    _ = pioProgramName;
    const mode = argIterator.next() orelse "desktop";
    const pythonInc = argIterator.next() orelse "desktop";
    const depHeaders = argIterator.next() orelse "desktop";
    _ = depHeaders;
    const compatHeaders = argIterator.next() orelse "platformio_clangd";
    _ = compatHeaders;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", arena);
    const compileFlags = argIterator.next() orelse
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ cwd, "zig-out/ogaboogaflags.txt" });

    const modeInfo = val.get(mode);

    var soBuf: [512]u8 = undefined;
    var soWriter = std.Io.File.stdout().writer(io, &soBuf);
    const stdout = &soWriter.interface;

    const deps = try getTheseDeps(arena, val, mode);

    var fileBuf: [512]u8 = undefined;
    {
        const cFlagsFile = try std.Io.Dir.createFileAbsolute(io, compileFlags, .{ .truncate = true });
        defer cFlagsFile.close(io);
        var compileFlagsWriter = cFlagsFile.writer(io, &fileBuf);
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
                .url => {},
            }
        }

        for (deps) |dep| {
            try cflagsiow.print("-Izig-out/include/{s}/{s}\n", .{ projectName, dep.name });
        }

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

    try stdout.flush();
}

fn isAsciiSpace(char: u8) bool {
    return char <= ' ' and char > 0;
}

const runProcess = if (builtin.zig_version.minor >= 12) std.process.Child.run else std.process.Child.exec;
