const std = @import("std");
const builtin = @import("builtin");
const r = @import("mod");
const helpers = @import("helpers");
const ZonType = helpers.buildInfo.ZonType;
const zon = @import("zon");
const zonParse = helpers.parseZon;
const inherit = helpers.inherit;

pub fn cleanTypeName(T: type, alloc: std.mem.Allocator) ![]const u8 {
    switch (@typeInfo(T)) {
        .int => |v| {
            var writer: std.Io.Writer.Allocating = .init(alloc);
            defer writer.deinit();
            try writer.writer.print("{s}int{}_t", .{
                if (v.signedness == .signed) "" else "u",
                v.bits,
            });
            return try writer.toOwnedSlice();
        },
        .float => |v| {
            if (v.bits == 32) {
                return try alloc.dupe(u8, "float");
            } else if (v.bits == 64) {
                return try alloc.dupe(u8, "double");
            } else unreachable;
        },
        .pointer => |v| {
            var writer: std.Io.Writer.Allocating = .init(alloc);
            defer writer.deinit();
            if (v.child == anyopaque) {
                try writer.writer.print("{s}void*", .{
                    if (v.is_const) "const " else "",
                });
                return try writer.toOwnedSlice();
            }
            const child = try cleanTypeName(v.child, alloc);
            // defer alloc.free(child);
            try writer.writer.print("{s}{s}*", .{
                if (v.is_const) "const " else "",
                child,
            });
            return try writer.toOwnedSlice();
        },
        .optional => |v| {
            std.debug.assert(@typeInfo(v.child) == .pointer);
            return try cleanTypeName(v.child, alloc);
        },
        else => {
            const name = @typeName(T);
            const buf = try alloc.alloc(u8, name.len);
            // defer alloc.free(buf);
            @memcpy(buf, name);
            var actual: []u8 = buf;
            for (buf, 0..) |c, i| {
                if (c == '.') {
                    actual = buf[i + 1 ..];
                }
            }
            const st = "struct_";
            if (std.mem.startsWith(u8, actual, st)) {
                actual = actual[st.len..];
            }
            const un = "union_";
            if (std.mem.startsWith(u8, actual, un)) {
                actual = actual[un.len..];
            }
            return try alloc.dupe(u8, actual);
        },
    }
}

pub fn markTypeDefined(
    T: type,
    alloc: std.mem.Allocator,
    resolvedTypes: *std.hash_map.StringHashMap(bool),
) !void {
    const cleanName = try cleanTypeName(T, alloc);
    // defer alloc.free(cleanName);
    try resolvedTypes.put(cleanName, true);
}

pub fn resolveInfoFor(
    T: type,
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    resolvedTypes: *std.hash_map.StringHashMap(bool),
) !void {
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            const cleanName = try cleanTypeName(T, alloc);
            // defer alloc.free(cleanName);
            if (resolvedTypes.contains(cleanName)) {
                return;
            }
            try markTypeDefined(T, alloc, resolvedTypes);
            inline for (s.fields) |f| {
                try resolveInfoFor(f.type, alloc, writer, resolvedTypes);
            }
            try writer.print("typedef struct {s} {{\n", .{cleanName});
            inline for (s.fields) |f| {
                const typeName = try cleanTypeName(f.type, alloc);
                // defer alloc.free(typeName);
                try writer.print("  {s} {s};\n", .{ typeName, f.name });
            }
            try writer.print("}} {s};\n\n", .{cleanName});
        },
        .@"union" => |u| {
            const cleanName = try cleanTypeName(T, alloc);
            // defer alloc.free(cleanName);
            if (resolvedTypes.contains(cleanName)) {
                return;
            }
            try resolvedTypes.put(cleanName, true);
            inline for (u.fields) |f| {
                try resolveInfoFor(f.type, alloc, writer, resolvedTypes);
            }
            try writer.print("typedef union {s} {{\n", .{cleanName});
            inline for (u.fields) |f| {
                const typeName = try cleanTypeName(f.type, alloc);
                // defer alloc.free(typeName);
                try writer.print("  {s} {s};\n", .{ typeName, f.name });
            }
            try writer.print("}} {s};\n\n", .{cleanName});
        },
        .pointer => |p| {
            try resolveInfoFor(p.child, alloc, writer, resolvedTypes);
        },
        else => {},
    }
}

pub fn abiCompatible(T: type) bool {
    switch (@typeInfo(T)) {
        .pointer => |v| {
            if (v.size == .slice) {
                return false;
            }
            return abiCompatible(v.child);
        },
        .type => return false,
        .int => |v| {
            if (v.bits % 8 != 0) {
                return false;
            }
            return true;
        },
        else => unreachable,
    }
}

pub fn writeFn(
    f: anytype,
    alloc: std.mem.Allocator,
    name: []const u8,
    writer: *std.Io.Writer,
    resolvedTypes: *std.hash_map.StringHashMap(bool),
) !void {
    switch (@typeInfo(@TypeOf(f))) {
        .@"fn" => |fun| {
            if (!fun.calling_convention.eql(.c)) {
                return;
            }

            inline for (fun.params) |param| {
                try resolveInfoFor(param.type.?, alloc, writer, resolvedTypes);
            }

            const ret = try cleanTypeName(fun.return_type.?, alloc);
            try writer.print("{s} ", .{ret});
            try writer.print("{s}", .{name});
            try writer.writeAll("(");
            inline for (fun.params, 0..) |param, i| {
                const cleanName = try cleanTypeName(param.type.?, alloc);
                // defer alloc.free(cleanName);
                try writer.writeAll(cleanName);
                if (i != fun.params.len - 1) {
                    try writer.writeAll(", ");
                }
            }
            try writer.writeAll(");\n\n");
        },
        else => {
            if (!abiCompatible(@TypeOf(f))) {
                return;
            }
            try resolveInfoFor(@TypeOf(f), alloc, writer, resolvedTypes);
            const cleanName = try cleanTypeName(@TypeOf(f), alloc);
            // defer alloc.free(cleanName);
            try writer.print("extern {s} {s};\n", .{ cleanName, name });
        },
    }
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    var zonParseArena: std.heap.ArenaAllocator = .init(allocator);
    const arena = zonParseArena.allocator();

    var val: ZonType = zonParse.parseZonStruct(
        arena,
        ZonType,
        zon.buildmodes,
        ".buildmodes",
    );

    try inherit.resolveInheritance(arena, &val);

    const alloc = std.heap.smp_allocator;
    var args = try std.process.argsWithAllocator(alloc);

    _ = args.next() orelse return error.NoArg;

    const out = args.next() orelse return error.NoFile;
    const mode = args.next() orelse return error.NoMode;
    const prefix = args.next() orelse return error.NoPrefix;

    const file = try std.fs.createFileAbsolute(out, .{
        .truncate = true,
    });

    var buf: [1024]u8 = undefined;

    var w = file.writer(&buf);
    const iow = &w.interface;
    var resolvedTypes: std.StringHashMap(bool) = .init(alloc);
    var ignoreDecls: std.StringHashMap(bool) = .init(alloc);

    try iow.print(
        \\// NOTE: THIS FILE IS AUTOGENERATED BY CHICOT!
        \\// DO NOT MANUALLY EDIT!!
        \\// To regenerate this file, run `zig build header -p {s}`
        \\
        \\#include "stdint.h"
        \\
    , .{prefix});

    for (val.get(mode).headergen) |info| {
        switch (info) {
            .addInclude => |v| {
                try iow.print("#include \"{s}\"\n", .{v});
            },
            .ignoreType => |v| {
                try resolvedTypes.put(v, true);
            },
            .ignoreDecl => |v| {
                try ignoreDecls.put(v, true);
            },
        }
    }

    try iow.writeAll(
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif // __cplusplus
        \\
        \\
    );

    inline for (@typeInfo(r).@"struct".decls) |field| {
        if (!ignoreDecls.contains(field.name)) {
            const value = @field(r, field.name);
            try writeFn(value, alloc, field.name, iow, &resolvedTypes);
        }
    }

    try iow.writeAll(
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif // __cplusplus
        \\
    );
    try iow.flush();
}
