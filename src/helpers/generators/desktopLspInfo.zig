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

/// A std.Io.Reader implementation that discards the comments from
/// a passed std.Io.Reader as it reads the data.
pub const JsonCommentDiscardReader = struct {
    reader: *std.Io.Reader,
    interface: std.Io.Reader,
    inComment: bool,
    inString: bool,
    seenOneSlash: bool,
    forwardBuf: ?u8 = null,
    debugStr: std.ArrayList(u8) = .{},
    debugAlloc: ?std.mem.Allocator = null,

    pub fn init(reader: *std.Io.Reader, buf: []u8) JsonCommentDiscardReader {
        return .{
            .inString = false,
            .inComment = false,
            .seenOneSlash = false,
            .reader = reader,
            .interface = .{
                .seek = 0,
                .end = 0,
                .buffer = buf,
                .vtable = &.{
                    .stream = stream,
                },
            },
        };
    }

    pub fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, len: std.Io.Limit) !usize {
        const self: *JsonCommentDiscardReader = @fieldParentPtr("interface", reader);

        const buffered = reader.buffered();

        var bytesWritten: usize = 0;
        // std.debug.print("Bytes: {} {}\n", .{ bytesWritten, len });

        // std.debug.print("Buffered: {}\n", .{buffered.len});
        for (buffered) |c| {
            bytesWritten = try self.writeChar(writer, c, len, bytesWritten);
            reader.toss(1);
            if (len != .unlimited and bytesWritten == len.toInt() orelse unreachable) {
                return bytesWritten;
            }
        }

        if (self.forwardBuf) |f| {
            // std.debug.print("Forwarding {c}\n", .{f});
            try writer.writeByte(f);
            bytesWritten += 1;
        }
        if (len != .unlimited and bytesWritten == len.toInt() orelse unreachable) {
            return bytesWritten;
        }
        // std.debug.print("No\n", .{});

        const lenInt = len.toInt() orelse std.math.maxInt(usize);

        while (bytesWritten < lenInt) {
            var readBuf: [64]u8 = undefined;

            // std.debug.print("Choosing from lens: {} {}\n", .{ lenInt - bytesWritten, readBuf.len });

            const slice = (&readBuf)[0..@min(lenInt - bytesWritten, readBuf.len)];
            if (slice.len == 0) {
                // std.debug.print("0 len slice ?\n\n", .{});
                break;
            }

            const readCount = try self.reader.readSliceShort(slice);

            const actualSlice = slice[0..readCount];
            if (readCount == 0) {
                // std.debug.print("0 len read slice ?\n\n", .{});
                return error.EndOfStream;
            }

            // it's impossible to overrun the writer len here bc we explicitly size our
            // buf for that to not happen with @min
            for (actualSlice) |c| {
                bytesWritten = try self.writeChar(writer, c, len, bytesWritten);
            }
            // std.debug.print("Wrote {} bytes\n", .{bytesWritten});

            if (len != .unlimited and bytesWritten == len.toInt() orelse unreachable) {
                return bytesWritten;
            }
            if (readCount < slice.len) {
                return bytesWritten;
            }
        }
        return bytesWritten;
    }

    // RULES:
    //
    // inString, inComment, seenOneSlash => behavior
    // true         true        true     => not allowed!
    // true         true        false    => not allowed!
    // true         false       _        =>
    //      forward char.
    //      if " or '
    //          unset inString
    // false        true        _        =>
    //      skip.
    //      if \n
    //          unset inComment
    // false        false       true     =>
    //      unset seenOneSlash.
    //      if /
    //          set inComment
    //      elseif " or '
    //          set inString. forward char
    //      else
    //          forward a slash BEFORE forwarding char
    // false        false       false    => forward char. if /, set inComment
    //      if /
    //          set seenOneSlash
    //      elseif " or '
    //          set inString. forward char
    //      else
    //          forward char

    /// this assumes len < currentCount
    pub fn writeChar(
        self: *JsonCommentDiscardReader,
        writer: *std.Io.Writer,
        char: u8,
        lenlim: std.Io.Limit,
        currentCount: usize,
    ) !usize {
        var ret = currentCount;
        const len: usize = lenlim.toInt() orelse std.math.maxInt(usize);
        if (self.forwardBuf) |f| {
            // std.debug.print("Forwarding char from buf '{c}'\n", .{f});
            try self.write(writer, f);
            ret += 1;
            self.forwardBuf = null;
        }
        // std.debug.print("Parsing char '{c}'\n", .{char});
        if (ret == len) {
            // std.debug.print("Forwarding char due to full buf \n", .{});
            self.forwardBuf = char;
            return ret;
        }
        if (self.inString and self.inComment) {
            @panic("Banned field combination!");
        }

        if (self.inString) {
            // std.debug.print("in string\n", .{});
            if (char == '"' or char == '\'') {
                // std.debug.print("exiting string\n", .{});
                self.inString = false;
            }
            try self.write(writer, char);
            ret += 1;
            return ret;
        }
        if (self.inComment) {
            // std.debug.print("in comment\n", .{});
            if (char == '\n') {
                // std.debug.print("ending comment\n", .{});
                self.inComment = false;
            }
            return ret;
        }
        if (self.seenOneSlash) {
            // std.debug.print("Last was slash\n", .{});
            self.seenOneSlash = false;
            if (char == '/') {
                // std.debug.print("entering comment\n", .{});
                self.inComment = true;
                return ret;
            }
            if (char == '"' or char == '\'') {
                self.inString = true;
            }
            try self.write(writer, '/');
            ret += 1;
            if (ret == len) {
                self.forwardBuf = char;
                return ret;
            }
            try self.write(writer, char);
            ret += 1;
            return ret;
        } else {
            if (char == '/') {
                self.seenOneSlash = true;
                return ret;
            }
            if (char == '"' or char == '\'') {
                self.inString = true;
            }
            try self.write(writer, char);
            ret += 1;
            return ret;
        }
    }

    pub fn write(self: *JsonCommentDiscardReader, writer: *std.Io.Writer, byte: u8) !void {
        if (self.debugAlloc) |alloc| {
            self.debugStr.append(alloc, byte) catch unreachable;
            // std.debug.print("Written bytes: {s}\n", .{self.debugStr.items});
        }
        // std.debug.print("Writing!\n", .{});
        try writer.writeByte(byte);
    }
};

pub fn main() !void {
    // var cwdBuf: [500]u8 = undefined;

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
    const cCppProps = argIterator.next() orelse
        try std.fmt.allocPrint(
            arena,
            "{s}/{s}",
            .{ cwd, "./zig-out/.vscode/c_cpp_properties.json" },
        );
    const currentCppProps = argIterator.next() orelse
        try std.fmt.allocPrint(
            arena,
            "{s}/{s}",
            .{ cwd, "./.vscode/c_cpp_properties.json" },
        );

    const modeInfo = val.get(mode);

    var soBuf: [512]u8 = undefined;
    var soWriter = std.fs.File.stdout().writer(&soBuf);
    const stdout = &soWriter.interface;

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
        try cflagsiow.print("-Izig-out/include/{s}\n", .{depHeaders});

        for (modeInfo.cpp.otherFlags) |flag| {
            try cflagsiow.print("{s}\n", .{flag});
        }

        for (modeInfo.cpp.include) |inc| {
            try cflagsiow.print("-I{s}\n", .{inc});
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

    {
        const currentPropsFile = try std.fs.openFileAbsolute(currentCppProps, .{
            .mode = .read_only,
        });
        defer currentPropsFile.close();
        var buf: [512]u8 = undefined;
        var r = currentPropsFile.reader(&buf);
        const ior = &r.interface;
        var jsonBuf: [512]u8 = undefined;
        var jsonCommentReader: JsonCommentDiscardReader = .init(ior, &jsonBuf);
        jsonCommentReader.debugAlloc = arena;

        var jsonScanner: std.json.Scanner.Reader = .init(
            arena,
            &jsonCommentReader.interface,
        );
        defer jsonScanner.deinit();

        var v = try std.json.parseFromTokenSource(CppPropsJson, arena, &jsonScanner, .{});
        defer v.deinit();

        // 1 for src/
        // 1 for Python.h
        const includePathLen = 1 + 1 + modeInfo.cpp.include.len;

        const include = try arena.alloc([]const u8, includePathLen);
        include[0] = "src";
        include[1] = pythonInc;

        @memcpy(include[2..], modeInfo.cpp.include);

        const cppstd = blk: {
            for (modeInfo.cpp.otherFlags) |f| {
                const stdflag = "-std=";
                if (std.mem.startsWith(u8, f, stdflag)) {
                    break :blk f[stdflag.len..];
                }
            }
            break :blk "c++11";
        };

        var defines: std.ArrayList([]const u8) = .{};
        defer defines.deinit(arena);

        if (modeInfo.cpp.define) |d| {
            var iter = d.map.iterator();

            while (iter.next()) |k| {
                if (k.value_ptr.*) |value| {
                    if (value.len == 0) {
                        try defines.append(arena, k.key_ptr.*);
                    } else {
                        try defines.append(
                            arena,
                            try std.fmt.allocPrint(
                                arena,
                                "{s}={s}",
                                .{ k.key_ptr.*, value },
                            ),
                        );
                    }
                }
            }
        }

        const config: CppPropsJson.Configuration = .{
            .name = mode,
            .includePath = include,
            .defines = defines.items,
            .cppStandard = cppstd,
            .compilerArgs = modeInfo.cpp.otherFlags,
            .compilerPath = "clang",
            .browse = .{
                .limitSymbolsToIncludedHeaders = false,
                .path = include,
            },
        };

        if (v.value.configurations.len == 0) {
            var configBuf: [1]CppPropsJson.Configuration = .{config};
            v.value.configurations = &configBuf;
        } else {
            // TODO: check if there is already a config slot that contains
            // data for this mode and overwrite it if so

            for (v.value.configurations, 0..) |conf, i| {
                if (std.mem.eql(u8, conf.name, config.name)) {
                    v.value.configurations[i] = conf;
                    break;
                }
            } else {
                const newMem = try arena.alloc(CppPropsJson.Configuration, v.value.configurations.len + 1);
                newMem[0] = config;
                @memcpy(newMem[1..], v.value.configurations);
                v.value.configurations = newMem;
            }
        }

        const cppPropsFile = try std.fs.createFileAbsolute(cCppProps, .{ .truncate = true });
        defer cppPropsFile.close();
        var cppPropsWriter = cppPropsFile.writer(&fileBuf);
        const cpppropsiow = &cppPropsWriter.interface;

        try std.json.fmt(v.value, .{}).format(cpppropsiow);

        try cpppropsiow.flush();
    }

    try stdout.flush();
}

fn isAsciiSpace(char: u8) bool {
    return char <= ' ' and char > 0;
}

const runProcess = if (builtin.zig_version.minor >= 12) std.process.Child.run else std.process.Child.exec;
