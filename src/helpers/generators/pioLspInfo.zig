const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("helpers");
const ZonType = helpers.buildInfo.ZonType;
const zon = @import("zon");
const zonParse = helpers.parseZon;
const inherit = helpers.inherit;

const PioInfo = struct {
    /// platformio.ini build_mode
    build_type: []const u8,
    /// the env to build in
    env_name: []const u8,
    /// An array of lib dirs ig? idk some of these dirs are also just
    /// straight up nonexistent
    libsource_dirs: [][]const u8,
    /// Macros to define. in the format of either "NAME" or "NAME=VALUE"
    defines: [][]const u8,
    includes: struct {
        /// The include paths currently referenced by the build
        build: [][]const u8,
        /// The actual include paths we care about
        compatlib: [][]const u8,
        /// The libstdc++ include paths
        toolchain: [][]const u8,
    },
    /// generic flags for c. Already in flag format!
    cc_flags: [][]const u8,
    /// generic flags for c++. Already in flag format!
    cxx_flags: [][]const u8,

    /// Path to gcc
    cc_path: []const u8,
    /// Path to g++
    cxx_path: []const u8,
    /// Path to gdb
    gdb_path: []const u8,
    /// Path to the elf (inside ./.pio) that is sent to the board
    prog_path: []const u8,
    /// I have no idea what this is. it's always been null in my testing
    svd_path: void,
    /// only been "gcc" inside my testing.
    compiler_type: []const u8,
    /// an array of objects describing the possible values after `pio run -t ...`
    targets: void,
    /// no idea what this encodes
    extra: void,
};

pub fn ParseStreamResult(T: type) type {
    var fields: [std.meta.fields(T).len]std.builtin.Type.StructField = undefined;

    comptime for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        fields[i] = field;
        if (field.type == void) {
            fields[i].type = void;
        } else {
            fields[i].type = std.json.Parsed(field.type);
        }
    };

    const internalType = @Type(.{ .@"struct" = .{
        .fields = &fields,
        .layout = .auto,
        .decls = &.{},
        .is_tuple = false,
    } });

    const Ret = struct {
        value: internalType,
        pub fn deinit(self: *@This()) void {
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (field.type != void) {
                    @field(self.value, field.name).deinit();
                }
            }
        }
    };
    return Ret;
}

fn printReaderPos(reader: *std.Io.Reader) void {
    if (reader.seek >= reader.buffer.len) {
        std.debug.print("Seek is past buffer len!\n", .{});
        return;
    }
    std.debug.print("Yuhh here's current reader pos: '{c}' {d} \"{s}\"\n", .{
        reader.buffer[reader.seek],
        reader.buffer[reader.seek],
        reader.buffer[reader.seek..@min(reader.buffer.len, reader.seek + 5)],
    });
}

pub fn parseStreamInto(T: type, alloc: std.mem.Allocator, reader: *std.Io.Reader) !ParseStreamResult(T) {
    var fieldsFound: usize = 0;

    var out: ParseStreamResult(T) = undefined;

    const fieldsExpected = std.meta.fields(T).len;

    while (true) {
        // ascii space and control characters (eg tab, space, newline, etc)
        // are all below 32
        //
        // 32 is space, above which are normal chars
        // printReaderPos(reader);
        while (reader.peekByte() catch break <= 32) {
            reader.toss(1);
        }

        var name = try reader.peekDelimiterExclusive('=');
        // +1 to also discard the =
        reader.toss(name.len + 1);
        // printReaderPos(reader);

        for (name, 0..) |c, i| {
            if (isAsciiSpace(c)) {
                name = name[0..i];
                break;
            }
        }

        const bytes = try reader.peekDelimiterInclusive('\n');

        var slice = try alloc.dupe(u8, bytes);

        reader.toss(slice.len);

        var nextPeek = try reader.peekByte();

        while (isAsciiSpace(nextPeek)) {
            const nextBytes = try reader.peekDelimiterInclusive('\n');

            const oldSlice = slice;

            slice = try std.mem.join(alloc, "", &.{ slice, nextBytes });
            alloc.free(oldSlice);

            reader.toss(nextBytes.len);
            nextPeek = reader.peekByte() catch |e|
                switch (e) {
                    error.EndOfStream => 'a',
                    else => return e,
                };
            // std.debug.print("Next byte to ppek yuhh: '{c}' {d}\n", .{ nextPeek, nextPeek });
            // printReaderPos(reader);
        }

        // std.debug.print("Parsing json slice: {s} for name {s}\n", .{ slice, name });

        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                if (field.type != void) {
                    @field(out.value, field.name) =
                        try std.json.parseFromSlice(field.type, alloc, slice, .{});
                    // if (@FieldType(T, field.name) == []const u8) {
                    //     std.debug.print("{s}\n", .{@field(out.value, field.name).value});
                    // } else {
                    //     std.debug.print("{any}\n", .{@field(out.value, field.name).value});
                    // }
                }
                fieldsFound += 1;
                break;
            }
        }
    }

    if (fieldsFound != fieldsExpected) {
        std.debug.print(
            "Did not get correct number of fields! expected {} but got {}\n",
            .{ fieldsExpected, fieldsFound },
        );
        return error.IncorrectFieldCount;
    }
    // std.debug.print("Phew we survived!\n", .{});
    return out;
}

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
    const mode = argIterator.next() orelse "teensy41";
    const compatHeaders = argIterator.next() orelse "platformio_clangd";
    const depHeaders = argIterator.next() orelse "lib";
    // std.debug.print("{s}\n", .{compatHeaders});
    const compileFlags = argIterator.next() orelse "./zig-out/ogaboogaflags.txt";

    if (val.get(mode).platformio == null) {
        std.debug.print("ERROR: build mode {s} does not have a platformio output type!\n", .{mode});
        return error.ModeNotAllowed;
    }

    const proc = try runProcess(.{
        .allocator = arena,
        .argv = &.{ pioProgramName, "project", "metadata", "-e", mode },
    });

    var reader = std.Io.Reader.fixed(proc.stdout);

    // the real info is preceded by a:
    // =======
    // idk how long the line is and idrc, we just check if the line starts with =
    while (try reader.peekByte() != '=') {
        _ = try reader.discardDelimiterInclusive('\n');
    }
    // eat the ==== line
    _ = try reader.discardDelimiterInclusive('\n');

    var v = try parseStreamInto(PioInfo, arena, &reader);
    defer v.deinit();

    var soBuf: [512]u8 = undefined;
    var soWriter = std.fs.File.stdout().writer(&soBuf);
    const stdout = &soWriter.interface;

    var fileBuf: [512]u8 = undefined;
    const file = try std.fs.createFileAbsolute(compileFlags, .{ .truncate = true });
    defer file.close();
    var compileFlagsWriter = file.writer(&fileBuf);
    const cflagsIow = &compileFlagsWriter.interface;

    const gppName = std.fs.path.basename(v.value.cxx_path.value);

    const gPlPl = "-g++";

    // try stdout.print("g++ name: {s}\n", .{gppName});
    // std.debug.print("g++ name: {s}\n", .{gppName});
    if (!std.mem.endsWith(u8, gppName, gPlPl)) {
        return error.NotGPlusPlus;
    }

    // TODO: use actual .hpp headers so we dont have to have this
    try cflagsIow.writeAll("-xc++\n");
    try cflagsIow.print("--target={s}\n\n", .{gppName[0 .. gppName.len - gPlPl.len]});

    for (v.value.cxx_flags.value) |define| {
        try cflagsIow.print("{s}\n", .{define});
    }
    try cflagsIow.writeAll("\n");

    for (v.value.includes.value.build) |inc| {
        // skip words that contain these triggers bc for SOME reason clangd does not like
        // that one specific directory. so we have the compatibility headers that i forgot
        // what modifications i made to them but they work
        const triggers: [3][]const u8 = .{ "cores", "teensy4", ".platformio" };
        var containsAllTriggers = true;
        for (triggers) |t| {
            if (!std.mem.containsAtLeast(u8, inc, 1, t)) {
                containsAllTriggers = false;
                break;
            }
        }
        if (!containsAllTriggers) {
            try cflagsIow.print("-I{s}\n", .{inc});
        } else {}
    }
    try cflagsIow.writeAll("\n");
    try cflagsIow.print(
        "-Izig-out/include/{s}/platforms/teensy/cores/teensy4\n",
        .{compatHeaders},
    );
    try cflagsIow.print(
        "-Izig-out/include/{s}\n",
        .{depHeaders},
    );
    try cflagsIow.writeAll("\n");

    for (v.value.includes.value.compatlib) |inc| {
        try cflagsIow.print("-I{s}\n", .{inc});
    }
    try cflagsIow.writeAll("\n");

    for (v.value.includes.value.toolchain) |inc| {
        try cflagsIow.print("-I{s}\n", .{inc});
    }
    try cflagsIow.writeAll("\n");

    for (v.value.defines.value) |define| {
        try cflagsIow.print("-D{s}\n", .{define});
    }
    try cflagsIow.writeAll("\n");

    try cflagsIow.flush();

    try stdout.flush();
}

fn isAsciiSpace(char: u8) bool {
    return char <= ' ' and char > 0;
}

const runProcess = if (builtin.zig_version.minor >= 12) std.process.Child.run else std.process.Child.exec;
