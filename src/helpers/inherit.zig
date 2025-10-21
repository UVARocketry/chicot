const std = @import("std");
const zonParse = @import("./parseZon.zig");
const buildInfo = @import("./buildInfo.zig");

const ZonType = buildInfo.ZonType;
const BuildDefaults = buildInfo.BuildDefaults;
const BuildInfo = buildInfo.BuildInfo;

/// Assigns ids to all elements inside the map, and then returns the number of
/// elements in the group
pub fn resolveIds(map: *ZonType) BuildInfo.IdType {
    var currentId: BuildInfo.IdType = 0;

    var iter = map.map.iterator();

    while (iter.next()) |v| {
        v.value_ptr.__id = currentId;
        currentId += 1;
    }
    return currentId;
}

pub const ResolveInheritanceError = error{ NilId, Loop, OutOfMemory };

/// what's the inherit policy:
///
/// - slices get appended
/// - strings dont get touched if they have a value
/// - nulls get replaced
/// - structs have these rules applied to their fields
/// - maps get put together with conflicts resolved by the original field's value
pub fn inherit(T: type, alloc: std.mem.Allocator, val: *T, from: T) !void {
    switch (@typeInfo(T)) {
        .@"struct" => {
            try inheritForObj(T, alloc, val, from);
            return;
        },
        .optional => |v| {
            if (from == null) {
                return;
            }
            if (val.*) |*nonOpt| {
                try inherit(v.child, alloc, nonOpt, from.?);
            } else {
                val.* = from;
            }
        },
        .pointer => |p| {
            if (T == []const u8 or T == []u8) {
                return;
            }
            if (p.size == .slice) {
                const ogLen = val.*.len;

                const ogSlice = val.*[0..];
                const buf = try alloc.alloc(p.child, ogLen + from.len);
                @memcpy(buf[0..ogLen], ogSlice);
                @memcpy(buf[ogLen..buf.len], from);
                val.* = buf;
                // val.* = try alloc.resize(val.*, val.*.len + from.len);
                // for (ogLen..val.*.len) |i| {
                //     val.*[i] = from[i - ogLen];
                // }
            } else {
                @compileError(std.fmt.comptimePrint(
                    "Type {} is not allowed in inherit()\n",
                    .{T},
                ));
            }
        },
        else => {
            std.debug.print("Encountered uninheritable type: {}\n", .{T});
            unreachable;
        },
    }
}

pub fn inheritForObj(T: type, alloc: std.mem.Allocator, val: *T, from: T) !void {
    if (comptime @hasDecl(T, "MapType")) {
        var valIter = val.map.iterator();

        while (valIter.next()) |v| {
            const key = v.key_ptr.*;

            if (from.hasKey(key)) {
                try inherit(T.MapType, alloc, v.value_ptr, from.get(key));
            } else {
                // std.debug.print("ignoring map key {s}\n", .{key});
            }
        }

        var fromIter = from.map.iterator();
        while (fromIter.next()) |f| {
            const key = f.key_ptr.*;
            if (!val.hasKey(key)) {
                try val.set(key, f.value_ptr.*);
                // std.debug.print("setting map key from {s}\n", .{key});
            }
        }
        return;
    }
    inline for (@typeInfo(T).@"struct".fields) |field| {
        comptime if (@hasDecl(T, "KeysToInherit")) {
            var found = false;
            for (T.KeysToInherit) |key| {
                if (std.mem.eql(u8, @tagName(key), field.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                continue;
            }
        };
        const fieldName = field.name;
        const FieldT = @FieldType(T, fieldName);

        const fieldPtr = &@field(val, fieldName);

        try inherit(FieldT, alloc, fieldPtr, @field(from, fieldName));
    }
}

pub fn resolveInheritanceForKey(
    alloc: std.mem.Allocator,
    map: *ZonType,
    key: []const u8,
    _bitset: u64,
    keyCount: u8,
) ResolveInheritanceError!void {
    const ptr = map.getPtr(key);
    const id = ptr.__id orelse return error.NilId;

    const bitMask = @as(u64, 1) << @intCast(id);

    if (_bitset & bitMask != 0 or keyCount == 0) {
        std.debug.print("Encountered inheritance loop at key {s}\n", .{key});
        return error.Loop;
    }

    var bitset = _bitset;
    bitset |= bitMask;

    if (ptr.inherit) |k| {
        resolveInheritanceForKey(alloc, map, k, bitset, keyCount - 1) catch |e| {
            switch (e) {
                error.Loop => {
                    std.debug.print("  while resolving key {s}\n", .{key});
                },
                else => {},
            }
            return e;
        };
        // std.debug.print("Resolving {s} inherit from {s}\n", .{ key, k });
        try inheritForObj(BuildInfo, alloc, ptr, map.get(k));
    }

    ptr.inherit = null;
}

pub fn resolveInheritance(alloc: std.mem.Allocator, map: *ZonType) !void {
    const elementCount = resolveIds(map);

    if (elementCount > 64) {
        std.debug.print(
            "Too many elements given to zon .buildmodes, expected max of {}, but got {}\n",
            .{ 64, elementCount },
        );
        @panic("no");
    }

    var iter = map.map.iterator();
    while (iter.next()) |v| {
        if (v.value_ptr.inherit) |_| {
            try resolveInheritanceForKey(alloc, map, v.key_ptr.*, 0, elementCount - 1);
        }
    }
}
