//! Edison, I'm sorry in advance for this file. This is very comptime heavy zig code,
//! which means it's probably very difficult to understand

const std = @import("std");

/// This prints obj, which can be anytype into zon format with indentation,
/// this only exists so that i can easily view the results of parsing the build.zig.zon,
/// this will be removed before the pr lands
pub fn gigaPrintThing(obj: anytype, indent: u32, writer: *std.Io.Writer) !void {
    const objInfo = @typeInfo(@TypeOf(obj));
    switch (objInfo) {
        .optional => {
            // if it's an optional type ?T, then if(obj) |o|
            // will make {o} a type T value if obj is not null
            if (obj) |o| {
                try gigaPrintThing(o, indent, writer);
            } else {
                try writer.print("null", .{});
            }
        },
        .@"struct" => |s| {
            try writer.print(".{{\n", .{});
            // if obj is a Map(T), then we need to print it specially
            if (@hasDecl(@TypeOf(obj), "MapType")) {
                // iterate over all hash map keys and stuff
                var iter = obj.map.iterator();
                while (iter.next()) |item| {
                    for (0..indent + 2) |_| {
                        try writer.print(" ", .{});
                    }
                    try writer.print(".{s} = ", .{item.key_ptr.*});
                    try gigaPrintThing(item.value_ptr.*, indent + 2, writer);
                    try writer.print(",\n", .{});
                }
            } else {
                inline for (s.fields) |f| {
                    for (0..indent + 2) |_| {
                        try writer.print(" ", .{});
                    }
                    try writer.print(".{s} = ", .{f.name});
                    try gigaPrintThing(@field(obj, f.name), indent + 2, writer);
                    try writer.print(",\n", .{});
                }
            }
            for (0..indent) |_| {
                try writer.print(" ", .{});
            }
            try writer.print("}}", .{});
        },
        .pointer => |p| {
            if (p.child == u8 and p.size == .slice) {
                try writer.print("\"{s}\"", .{obj});
            } else if (p.size == .slice) {
                try writer.print(".{{\n", .{});
                for (obj) |v| {
                    for (0..indent + 2) |_| {
                        try writer.print(" ", .{});
                    }
                    try gigaPrintThing(v, indent + 2, writer);
                    try writer.print(",\n", .{});
                }
                for (0..indent) |_| {
                    try writer.print(" ", .{});
                }
                try writer.print("}}", .{});
            } else {
                try writer.print("{*}", .{obj});
            }
        },
        else => {
            try writer.print("{}", .{obj});
        },
    }
}

/// This is a hashmap container that has a special field (MapType) that allows
/// comptime reflection stuff to detect that this struct is a Map
pub fn Map(T: type) type {
    return struct {
        pub const Self = Map(T);
        /// This decl exists solely so that comptime stuff can detect if a struct
        /// is a ComptimeMap or if it is just a regular struct
        pub const MapType = T;

        map: std.StringHashMap(T),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .map = .init(allocator),
            };
        }

        pub fn set(self: *Self, name: []const u8, value: T) !void {
            try self.map.put(name, value);
        }
        pub fn get(self: *const Self, name: []const u8) T {
            return self.map.get(name) orelse unreachable;
        }
        pub fn getPtr(self: *const Self, name: []const u8) *T {
            return self.map.getEntry(name).?.value_ptr;
        }
        pub fn hasKey(self: *const Self, name: []const u8) bool {
            return self.map.contains(name);
        }
        pub fn format(self: Self, writer: *std.Io.Writer) !void {
            var iter = self.map.iterator();
            while (iter.next()) |item| {
                try writer.print(".{s} = {f},\n", .{ item.key_ptr.*, item.value_ptr.* });
            }
        }
    };
}
// general thoughts on parsing zon:
//
// - prolly have an intermediate struct defined by us with specialized convert() methods
// - prolly have a NamedArray or Map (eg for buildmodes.platformio.platformio.envs)
// - arrays get parsed as tuples
// - be able to convert enums

/// This function returns true if two types can be trivially converted between another,
/// However, this function's parameter order DOES MATTER.
pub fn strictTrivialTypeMismatch(T1: type, T2: type) bool {
    if (T1 == comptime_int and @typeInfo(T2) == .int) {
        return true;
    }
    if (T1 == comptime_float and @typeInfo(T2) == .float) {
        return true;
    }
    // @compileLog(std.fmt.comptimePrint("{}", .{T1}));
    if (T1 == []u8 or T1 == []const u8) {
        // @compileLog("Is array");
        const t2Info = @typeInfo(T2);
        switch (t2Info) {
            .array => |a| {
                return a.child == u8;
            },
            .pointer => |p| {
                if (p.size == .one) {
                    const childInfo = @typeInfo(p.child);
                    if (childInfo == .array and childInfo.array.child == u8 and childInfo.array.sentinel().? == 0) {
                        return true;
                    }
                }
            },
            else => return false,
        }
    }
    return false;
}

/// This essentially just calls strictTrivialTypeMismatch with parameters both ways
/// to check if types can be converted
pub fn trivialTypeMismatch(T1: type, T2: type) bool {
    if (@typeInfo(T1) == .optional) {
        // t1 = t2, t2 can ONLY be optional if t1 is also optional, hence putting
        // this if inside the parent if
        if (@typeInfo(T2) == .optional) {
            return trivialTypeMismatch(
                @typeInfo(T1).optional.child,
                @typeInfo(T2).optional.child,
            );
        }
        return trivialTypeMismatch(@typeInfo(T1).optional.child, T2);
    }
    return strictTrivialTypeMismatch(T1, T2) or strictTrivialTypeMismatch(T2, T1);
}

/// Parses the zon object (newVal) into the slice type (val).
/// An allocator is needed because the backing memory for the slice is created at runtime
pub fn parseIntoSlice(
    allocator: std.mem.Allocator,
    T: type,
    val: *T,
    newVal: anytype,
    comptime currentField: []const u8,
) void {
    const T2 = @TypeOf(newVal);
    const newValInfo = @typeInfo(T2);

    // Zon stores arrays as tuples, which zig @typeInfo classifies as structs
    if (newValInfo != .@"struct") {
        // if we are not a struct (aka definitely not a tuple (aka definitely not an
        // array)), then throw a compile err
        @compileError(
            std.fmt.comptimePrint(
                "Expected a tuple type to parse into slice field {s}: {}, got {}",
                .{ currentField, T, T2 },
            ),
        );
    }
    // if we are definitely not a tuple, then throw an error
    if (!newValInfo.@"struct".is_tuple) {
        @compileError(
            std.fmt.comptimePrint(
                "Expected a tuple type to parse into slice field {s}: {}, got {}",
                .{ currentField, T, T2 },
            ),
        );
    }

    // zig typeInfo classifies slices (`[]S`) as pointers,
    // so to get the member type (eg `S`), we do this
    const MemberType = @typeInfo(T).pointer.child;

    // The number of elements in the array
    const fieldCount = std.meta.fields(T2).len;

    // allocate a buffer to store our values in
    var backingBuf: []MemberType = allocator.alloc(MemberType, fieldCount) catch unreachable;
    inline for (newValInfo.@"struct".fields, 0..) |field, i| {
        // parse the array values
        parseIntoType(
            allocator,
            MemberType,
            &backingBuf[i],
            @field(newVal, field.name),
            currentField ++ "." ++ std.fmt.comptimePrint("{}", .{i}),
        );
    }
    val.* = backingBuf[0..];
}

/// Parses zon value {newVal} into val, directly does val = newVal if the type mismatch
/// is trivially different (eg for the various string types or integer types)
pub fn parseIntoType(allocator: std.mem.Allocator, T: type, val: *T, newVal: anytype, comptime currentField: []const u8) void {
    const T2 = @TypeOf(newVal);
    const tInfo = @typeInfo(T);
    // if val's type is an optional, then unpack that and call parseIntoType again
    if (tInfo == .optional) {
        if (@typeInfo(T2) == .null) {
            val.* = null;
            return;
        }
        const NewT = tInfo.optional.child;
        var nonOpt: NewT = undefined;
        parseIntoType(allocator, NewT, &nonOpt, newVal, currentField);
        val.* = nonOpt;
        return;
    }
    // tInfo will be .pointer for slices and .array for sized arrays
    const trivial = comptime trivialTypeMismatch(T, T2);
    if (T2 != T and !trivial) {
        // .pointer means we are parsing a slice because zon cannot have pointers
        if (tInfo == .pointer) {
            parseIntoSlice(allocator, T, val, newVal, currentField);
            return;
        }
        // parsing into comptime map
        if (tInfo == .@"struct" and @hasDecl(T, "MapType")) {
            parseIntoComptimeMap(allocator, T, val, newVal, currentField);
            return;
        }
        // parsing into generic data struct
        if (tInfo == .@"struct") {
            parseIntoStruct(allocator, T, val, newVal, currentField);
            return;
        }
        // parsing into enum value
        if (tInfo == .@"enum") {
            parseIntoEnum(T, val, newVal, currentField);
            return;
        }
        if (tInfo == .@"union") {
            parseIntoUnion(allocator, T, val, newVal, currentField);
            return;
        }
        // if we couldnt parse, then throw a compile error
        @compileLog(std.fmt.comptimePrint("zon info: {}", .{@typeInfo(T2)}));
        @compileLog(std.fmt.comptimePrint("expected info: {}", .{@typeInfo(T)}));
        @compileError(std.fmt.comptimePrint(
            "Cannot convert from zon type {} to expected type {} for field {s}",
            .{ T2, T, currentField },
        ));
    }
    // for trivial mismatches, we have this
    val.* = newVal;
}

// parsing into comptime map
pub fn parseIntoComptimeMap(allocator: std.mem.Allocator, T: type, val: *T, newVal: anytype, comptime currentField: []const u8) void {
    const T2 = @TypeOf(newVal);
    const t2Info = @typeInfo(T2);
    if (t2Info != .@"struct") {
        @compileError(std.fmt.comptimePrint(
            "Expected a struct type to parse into a comptime map for field {s}",
            .{currentField},
        ));
    }
    const fieldCount = std.meta.fields(T2).len;
    if (t2Info.@"struct".is_tuple and fieldCount != 0) {
        @compileError(std.fmt.comptimePrint(
            "Expected a struct, not a tuple, type to parse into a comptime map for field {s}",
            .{currentField},
        ));
    }
    val.* = T.init(allocator);
    const BackingT = T.MapType;
    // loop through the zon fields
    inline for (t2Info.@"struct".fields) |field| {
        // create a value to parse into
        var value: BackingT = undefined;
        // get the zon version of the current value
        const childval = @field(newVal, field.name);
        // parse yuhh
        parseIntoType(
            allocator,
            BackingT,
            &value,
            childval,
            currentField ++ "." ++ field.name,
        );
        // now we set the map value.
        // catch unreachable bc im too lazy to add try to everything
        val.set(field.name, value) catch unreachable;
    }
}
/// This parses a zon enum value into an enum.
/// Technically this can be done with trivial type mismatch, but making our own function
/// gives us better errors,
pub fn parseIntoEnum(T: type, val: *T, newVal: anytype, comptime currentField: []const u8) void {
    const T2 = @TypeOf(newVal);
    const t2Info = @typeInfo(T2);

    if (t2Info != .enum_literal) {
        @compileError(std.fmt.comptimePrint(
            "Expected an enum literal for field {s} to put into enum type {}, but got {}",
            .{ currentField, T, newVal },
        ));
    }

    // we add the comptime keyword before std.meta..... to force the analysis at comptime
    // otherwise the compileError will always be analyzed and this statement will always
    // throw a compile error
    val.* = comptime std.meta.stringToEnum(T, @tagName(newVal)) orelse @compileError(
        std.fmt.comptimePrint(
            "Could not find field {} in enum {} to set value {s}",
            .{ newVal, T, currentField },
        ),
    );
}

/// Returns true if {T}'s field {fieldName} is optional
pub fn isOptional(T: type, comptime fieldName: []const u8) bool {
    switch (@typeInfo(@FieldType(T, fieldName))) {
        .optional => return true,
        else => return false,
    }
}

/// Returns the default value for type {T}'s field {fieldName}
pub fn defaultPtr(T: type, comptime fieldName: []const u8) ?@FieldType(T, fieldName) {
    comptime for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, fieldName, f.name)) {
            return f.defaultValue();
        }
    };
    return null;
}

pub fn parseIntoUnion(
    allocator: std.mem.Allocator,
    T: type,
    val: *T,
    newVal: anytype,
    comptime currentField: []const u8,
) void {
    const info = @typeInfo(@TypeOf(newVal)).@"struct";

    comptime var i = 0;
    if (info.fields.len != 1) {
        @compileError(std.fmt.comptimePrint("Expected only one field passed in zon type at {s} while setting union type {}, instead got {}\n", .{ currentField, T, info.fields.len }));
    }
    inline for (info.fields) |field| {
        const fname = field.name;
        if (@hasField(T, fname)) {
            const ExpectingType = @FieldType(T, field.name);
            var container: ExpectingType = undefined;
            parseIntoType(
                allocator,
                ExpectingType,
                &container,
                @field(newVal, field.name),
                currentField ++ "." ++ field.name,
            );
            val.* = @unionInit(T, fname, container);
            break;
        }
        i += 1;
    } else {
        @compileError(std.fmt.comptimePrint("Field '{s}' is not contained in union type {}, but is in passed zon type (while setting {s})\n", .{ info.fields[i], T, currentField }));
    }
}

/// Parses the zon value {newVal} into the struct {val}
pub fn parseIntoStruct(
    allocator: std.mem.Allocator,
    T: type,
    val: *T,
    newVal: anytype,
    comptime currentField: []const u8,
) void {
    const info = @typeInfo(@TypeOf(newVal)).@"struct";
    // Create an array of field names. This field tracks which fields we havent already
    // seen in the zon type. This is so that we can iterate over this array after parsing
    // the zon value and throw errors for missed non-optional fields
    comptime var fields: [std.meta.fields(T).len][]const u8 = undefined;
    comptime for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
        fields[i] = f.name;
    };
    inline for (info.fields) |field| {
        const fname = field.name;
        if (!@hasField(T, fname)) {
            @compileError(std.fmt.comptimePrint("Field '{s}' is not contained in type {}, but is in passed zon type (while setting {s})\n", .{ fname, T, currentField }));
            // return error.FieldNotFound;
        }
        // remove the current field from being tracked
        comptime for (fields, 0..) |n, j| {
            if (std.mem.eql(u8, n, fname)) {
                fields[j] = "";
            }
        };
        // parse the sub value
        parseIntoType(
            allocator,
            @FieldType(T, fname),
            &@field(val.*, fname),
            @field(newVal, fname),
            currentField ++ "." ++ field.name,
        );
    }
    // checks for all fields that we havent encountered, then either sets them to null
    // or throws an error if they cant be set to null
    inline for (fields) |n| {
        if (n.len == 0) {
            continue;
        }
        const FieldT = @FieldType(T, n);
        if (comptime defaultPtr(T, n)) |p| {
            // if it has a default value, set it to that
            @field(val.*, n) = p;
        } else if (comptime isOptional(T, n)) {
            // if it's an optional type, set to null
            @field(val.*, n) = null;
        } else {
            // throw an error if we can't set it
            @compileError(std.fmt.comptimePrint(
                "Field '{s}' in type {} is not set, even though it's type ({}) is not optional\n",
                .{ currentField ++ "." ++ n, T, FieldT },
            ));
        }
    }
}

// Parses a zon object into something and then return the result
pub fn parseZonStruct(
    allocator: std.mem.Allocator,
    Ret: type,
    val: anytype,
    comptime currentField: []const u8,
) Ret {
    var ret: Ret = undefined;
    parseIntoType(allocator, Ret, &ret, val, currentField);
    return ret;
}
