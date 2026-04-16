const std = @import("std");
const builtin = @import("builtin");

const Config = struct {
    home: ?[]const u8,
    winePrefix: ?[]const u8,
};

var config: Config = .{
    .home = null,
    .winePrefix = null,
};

pub fn init(env: *const std.process.Environ.Map) !void {
    if (config.home == null) {
        config.home = env.get("HOME") orelse null;
    }
    if (config.winePrefix == null) {
        config.winePrefix = env.get("WINEPREFIX") orelse null;
    }
}

pub fn convertWinePathToLinuxPath(
    alloc: std.mem.Allocator,
    path: []const u8,
) ![]const u8 {
    const home = config.home orelse return error.HomeEnvVarNotFound;

    const winePrefix = config.winePrefix orelse try std.Io.Dir.path.join(
        alloc,
        &.{ home, ".wine" },
    );
    defer alloc.free(winePrefix);

    std.debug.print("WINEPREFIX: {s}\n", .{winePrefix});

    const actualWineLocation = try std.Io.Dir.path.join(
        alloc,
        &.{ winePrefix, "drive_c" },
    );
    defer alloc.free(actualWineLocation);

    std.debug.print("C:\\: {s}\n", .{actualWineLocation});

    const newName = try std.Io.Dir.path.join(
        alloc,
        &.{
            actualWineLocation,
            path[3..],
        },
    );
    for (newName, 0..) |c, i| {
        if (c == '\\') {
            newName[i] = '/';
        }
    }
    std.debug.print("New name: {s}\n", .{newName});
    return newName;
}

pub fn optionallyConvertWinePath(
    alloc: std.mem.Allocator,
    path: []const u8,
    targetOs: std.Target.Os.Tag,
) ![]const u8 {
    if (builtin.os.tag == .linux and
        targetOs == .windows)
    {
        const name = path;
        std.debug.print("Cross compiling!\n", .{});
        std.debug.print("Resolving: {s}\n", .{name});
        if (std.mem.startsWith(u8, name, "C:/") or std.mem.startsWith(u8, name, "C:\\")) {
            const newName = try convertWinePathToLinuxPath(alloc, name);
            return newName;
        } else {
            return path;
        }
    } else {
        return path;
    }
}
