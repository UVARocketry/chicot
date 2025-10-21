//! This file is for outputting a library.json that platformio can use to find
//! sub-dependencies.
//!
//! This should ideally be ran in CI after every push

const std = @import("std");
const helpers = @import("helpers");
const ZonType = helpers.buildInfo.ZonType;
const zon = @import("zon");
const zonParse = helpers.parseZon;
const inherit = helpers.inherit;

// expected format:
// https://docs.platformio.org/en/latest/manifests/library-json/index.html
//
// this struct excludes dependencies bc i didnt want to implement that kinda generic string -> string mapping inside getFileContents
const JsonInfo = struct {
    // TODO: we CAN get the repo url with `git remote get-url origin` and add
    // that to the build pipeline as an input to this
    pub const Repo = struct {
        type: []const u8 = "git",
        url: []const u8,
    };

    pub const Author = struct {
        name: []const u8 = "UVA Rocketry",
        email: []const u8 = "",
        url: []const u8 = "https://github.com/UvaRocketry",
    };
    name: []const u8,
    version: []const u8,
    description: []const u8,
    keywords: []const u8 = "",
    repository: Repo = .{ .url = "" },
    authors: []const Author = &.{.{}},
    license: []const u8 = "idkyet",
    /// same as git repo prolly
    homepage: []const u8 = "",
    frameworks: []const u8 = "*",
    platforms: []const u8 = "*",
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

pub fn jsonOutValue(
    T: type,
    value: *const T,
    json: *std.json.Stringify,
    close: bool,
) !void {
    if (T == []const u8 or T == []u8) {
        try json.write(value);
        return;
    }

    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            try json.beginObject();
            inline for (s.fields) |field| {
                try json.objectField(field.name);
                try jsonOutValue(field.type, &@field(value, field.name), json, true);
            }
            if (close) {
                try json.endObject();
            }
        },
        .pointer => |v| {
            comptime std.debug.assert(v.size == .slice);
            try json.beginArray();
            for (value.*) |item| {
                try jsonOutValue(@TypeOf(item), &item, json, true);
            }
            if (close) {
                try json.endArray();
            }
        },
        else => comptime unreachable,
    }
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

    var argIterator = try std.process.argsWithAllocator(allocator);
    if (argIterator.next()) |_| {} else {
        return error.NoArgs;
    }
    const name = argIterator.next() orelse return error.NoFileArg;

    var allocatingWriter: std.Io.Writer.Allocating = .init(allocator);
    defer allocatingWriter.deinit();

    const outputFile = try std.fs.createFileAbsolute(name, .{ .truncate = true });
    defer outputFile.close();
    var buf: [1024]u8 = undefined;
    var outWriter = outputFile.writer(&buf);
    const outIow = &outWriter.interface;

    var json: std.json.Stringify = .{
        .writer = outIow,
    };

    const info: JsonInfo = .{
        .name = @tagName(zon.name),
        .version = zon.version,
        .description = "",
    };

    try jsonOutValue(JsonInfo, &info, &json, false);
    try json.objectField("dependencies");
    try json.beginObject();

    const DependencyInfo = struct {
        name: []const u8,
        url: []const u8,
    };

    var deps: std.ArrayList(DependencyInfo) = .{};
    defer deps.deinit(allocator);
    var mapIter = val.map.iterator();

    // what follows is a very scary nested loop, just follow the comments and
    // you will be fine

    // for all elements in the buildmodes map...
    while (mapIter.next()) |next| {
        // if they have a valid configuration...
        if (next.value_ptr.platformio != null) {
            continue;
        }

        // for all actual dependencies it uses...
        for (next.value_ptr.dependencies) |dep| {
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
                            // create a dependency object
                            break :blk .{
                                .name = f.name,
                                .url = @field(zon.dependencies, f.name).url,
                            };
                        }
                    }
                    @panic("No depency found!");
                };
                // append the dependency to the array
                try deps.append(allocator, newDep);
            }
        }
    }

    // the platformio dependency map format for library.json is
    //
    // "depname": "depurl"
    //
    // https://docs.platformio.org/en/latest/manifests/library-json/fields/dependencies.html
    for (deps.items) |v| {
        try json.objectField(v.name);
        try json.write(v.url);
    }

    try json.endObject();
    try json.endObject();

    try outIow.flush();

    const outWriterIow = &outWriter.interface;
    try outWriterIow.writeAll(
        allocatingWriter.writer.buffer[0..allocatingWriter.writer.end],
    );
    try outWriterIow.flush();
}
