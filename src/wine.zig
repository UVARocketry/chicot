const std = @import("std");
const builtin = @import("builtin");
pub fn convertWinePathToLinuxPath(
    alloc: std.mem.Allocator,
    path: []const u8,
) ![]const u8 {
    const home = try std.process.getEnvVarOwned(alloc, "HOME");
    std.debug.print("HOME: {s}\n", .{home});
    defer alloc.free(home);
    const winePrefix = std.process.getEnvVarOwned(
        alloc,
        "WINEPREFIX",
    ) catch try std.fs.path.join(
        alloc,
        &.{ home, ".wine" },
    );
    std.debug.print("WINEPREFIX: {s}\n", .{winePrefix});
    defer alloc.free(winePrefix);
    const actualWineLocation = try std.fs.path.join(
        alloc,
        &.{ winePrefix, "drive_c" },
    );
    std.debug.print("C:\\: {s}\n", .{actualWineLocation});
    defer alloc.free(actualWineLocation);
    const newName = try std.fs.path.join(
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
