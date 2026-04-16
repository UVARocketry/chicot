const std = @import("std");
const builtin = @import("builtin");
const r = @import("mod");
const helpers = @import("helpers");
const ZonType = helpers.buildInfo.ZonType;
const zon = @import("zon");
const zonParse = helpers.parseZon;
const inherit = helpers.inherit;

const Err = std.mem.Allocator.Error || std.Io.Writer.Error;

pub fn cleanTypeName(T: type, alloc: std.mem.Allocator) Err![]const u8 {
    switch (@typeInfo(T)) {
        .int => |v| {
            var writer: std.Io.Writer.Allocating = .init(alloc);
            defer writer.deinit();
            if (T == u8) {
                try writer.writer.print("char", .{});
            } else {
                try writer.writer.print("{s}int{}_t", .{
                    if (v.signedness == .signed) "" else "u",
                    v.bits,
                });
            }
            return try writer.toOwnedSlice();
        },
        .float => |v| {
            if (v.bits == 32) {
                return try alloc.dupe(u8, "float");
            } else if (v.bits == 64) {
                return try alloc.dupe(u8, "double");
            } else unreachable;
        },
        .@"fn" => |f| {
            var writer: std.Io.Writer.Allocating = .init(alloc);
            defer writer.deinit();

            const retTyp = try cleanTypeName(f.return_type.?, alloc);

            try writer.writer.print("{s} (*)(", .{retTyp});

            inline for (f.params, 0..) |p, i| {
                const param = try cleanTypeName(p.type.?, alloc);
                try writer.writer.writeAll(param);
                if (i != f.params.len - 1) {
                    try writer.writer.writeAll(", ");
                }
            }
            try writer.writer.writeAll(")");

            return try writer.toOwnedSlice();
        },
        .pointer => |v| {
            var writer: std.Io.Writer.Allocating = .init(alloc);
            defer writer.deinit();
            if (T == *anyopaque) {
                try writer.writer.print("{s}void*", .{
                    if (v.is_const) "const " else "",
                });
                return try writer.toOwnedSlice();
            }
            const child = try cleanTypeName(v.child, alloc);
            const isFn = @typeInfo(v.child) == .@"fn";
            // defer alloc.free(child);
            try writer.writer.print("{s}{s}{s}", .{
                if (isFn) "" else if (v.is_const) "const " else "",
                child,
                if (isFn) "" else "*",
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
            defer alloc.free(buf);
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
            if (actual[actual.len - 1] == ')') {
                actual = actual[0 .. actual.len - 1];
            }
            return try alloc.dupe(u8, actual);
        },
    }
}

pub fn markTypeDefined(
    T: type,
    alloc: std.mem.Allocator,
    resolvedTypes: *std.hash_map.StringHashMap(bool),
) Err!void {
    const cleanName = try cleanTypeName(T, alloc);
    // defer alloc.free(cleanName);
    try resolvedTypes.put(cleanName, true);
}

pub fn resolveInfoFor(
    T: type,
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    resolvedTypes: *std.hash_map.StringHashMap(bool),
) Err!void {
    const cleanName = try cleanTypeName(T, alloc);
    // std.log.info("Found type: {s}, {}\n", .{ cleanName, T });
    if (resolvedTypes.contains(cleanName)) {
        // std.log.info("Skipping type: {s}, {}\n", .{ cleanName, T });
        return;
    }
    // std.log.info("Parsing type: {s}, {}\n", .{ cleanName, T });
    try markTypeDefined(T, alloc, resolvedTypes);
    switch (@typeInfo(T)) {
        .@"enum" => |e| {
            const backingName = try cleanTypeName(e.tag_type, alloc);
            try writer.print(
                \\#ifdef __cplusplus
                \\enum class {s} : {s} {{
                \\
            , .{ cleanName, backingName });
            inline for (e.fields) |f| {
                try writer.print("    {s} = {},\n", .{
                    f.name,
                    f.value,
                });
            }
            try writer.print(
                \\}};
                \\#else
                \\typedef enum {s} : {s} {{
                \\
            , .{ cleanName, backingName });
            inline for (e.fields) |f| {
                try writer.print("    {s}_{s} = {},\n", .{
                    cleanName,
                    f.name,
                    f.value,
                });
            }
            try writer.print("}} {s};\n#endif\n\n", .{cleanName});
        },
        .@"opaque" => {
            try writer.print("struct {s};\n", .{cleanName});
            return;
        },
        .@"struct" => |s| {
            inline for (s.fields) |f| {
                try resolveInfoFor(f.type, alloc, writer, resolvedTypes);
            }
            // TODO: packed structs are bad
            const packedName = if (s.layout == .@"packed") "__attribute__((packed)) " else "";
            try writer.print("typedef struct {s}{s} {{\n", .{ packedName, cleanName });
            inline for (s.fields) |f| {
                const typeName = try cleanTypeName(f.type, alloc);
                // defer alloc.free(typeName);
                try writer.print("    {s} {s};\n", .{ typeName, f.name });
            }
            try writer.print("}} {s};\n\n", .{cleanName});
        },
        .@"fn" => |f| {
            inline for (f.params) |param| {
                try resolveInfoFor(param.type.?, alloc, writer, resolvedTypes);
            }
            try resolveInfoFor(f.return_type.?, alloc, writer, resolvedTypes);
        },
        .@"union" => |u| {
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
        .optional => |p| {
            // std.log.info("Resolving optional: {}\n", .{p.child});
            switch (@typeInfo(p.child)) {
                .pointer => |ptr| {
                    try resolveInfoFor(ptr.child, alloc, writer, resolvedTypes);
                },
                else => {
                    // std.log.warn("Unknown optional child for: {s}, {}, {}\n", .{ cleanName, T, @typeInfo(T) });
                },
            }
        },
        else => {
            // std.log.warn("Unable to resolve type: {s}, {}, {}\n", .{ cleanName, T, @typeInfo(T) });
        },
    }
}

pub fn abiCompatible(T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct" => |v| {
            return v.layout == .@"extern";
        },
        .pointer => |v| {
            if (v.size == .slice) {
                return false;
            }
            // allow any pointer child type to be abi compatible because pointers always are
            return true;
        },
        .type => return false,
        .int => |v| {
            if (v.bits % 8 != 0) {
                return false;
            }
            return true;
        },
        .@"enum" => return true,
        else => {
            @compileError(std.fmt.comptimePrint("Type {} is not abi compatible!", .{T}));
        },
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
            // std.log.info("Parsing function {s}, {}, conv(.{})\n", .{ name, @TypeOf(f), fun.calling_convention });

            inline for (fun.params) |param| {
                try resolveInfoFor(param.type.?, alloc, writer, resolvedTypes);
            }
            try resolveInfoFor(fun.return_type.?, alloc, writer, resolvedTypes);

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
        .type => {
            try resolveInfoFor(f, alloc, writer, resolvedTypes);
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

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    defer _ = init.arena.reset(.free_all);

    const io = init.io;

    var val: ZonType = zonParse.parseZonStruct(
        arena,
        ZonType,
        zon.buildmodes,
        ".buildmodes",
    );

    try inherit.resolveInheritance(arena, &val);

    var args = try init.minimal.args.iterateAllocator(init.gpa);

    _ = args.next() orelse return error.NoArg;

    const out = args.next() orelse try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        "thing.h",
        arena,
    );
    const mode = args.next() orelse "desktop";
    const prefix = args.next() orelse ".";

    const file = try std.Io.Dir.createFileAbsolute(io, out, .{
        .truncate = true,
    });
    defer file.close(io);

    var buf: [1024]u8 = undefined;

    var w = file.writer(io, &buf);
    const iow = &w.interface;
    var resolvedTypes: std.StringHashMap(bool) = .init(arena);
    var ignoreDecls: std.StringHashMap(bool) = .init(arena);

    try iow.print(
        \\// NOTE: THIS FILE IS AUTOGENERATED BY CHICOT!
        \\// DO NOT MANUALLY EDIT!!
        \\// To regenerate this file, run `zig build header -p {s}`
        \\
        \\#pragma once
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
            try writeFn(value, arena, field.name, iow, &resolvedTypes);
        }
    }

    try iow.writeAll(
        \\#ifdef __cplusplus
        \\}
        \\#endif // __cplusplus
        \\
    );
    try iow.flush();
}
