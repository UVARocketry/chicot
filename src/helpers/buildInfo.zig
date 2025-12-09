const std = @import("std");
const zonParse = @import("./parseZon.zig");
pub const PlatformIoInfo = struct {
    // pub const FieldEnum = std.meta.FieldEnum(@This());
    //
    // pub const KeysToInherit = [_]FieldEnum{
    //     .build_type,
    //     .board,
    //     .platform,
    //     .framework,
    //     .extra_scripts,
    //     .lib_deps,
    // };
    // const Env = struct {
    //     pub fn format(self: @This(), writer: *std.Io.Writer) !void {
    //         try gigaPrintThing(self, 0, writer);
    //     }
    // };
    build_type: []const u8 = "release",
    platform: []const u8 = "teensy",
    board: []const u8 = "teensy41",
    framework: []const u8 = "arduino",
    // This should ADD to default extra_scripts.
    // Default extra_scripts should include a default python script that:
    // - builds the libzig to link in
    // - and probably diffs the current platformio with the one zig expects,
    // and tells the user to regen platformio.ini if not matching
    extra_scripts: [][]const u8 = &.{},
    // This should ADD to default lib_deps
    lib_deps: [][]const u8 = &.{},
    // envs: zonParse.Map(Env),
};

pub const CppInfo = struct {
    define: ?zonParse.Map(?[]const u8) = null,
    include: [][]const u8 = &.{},
    linkPath: [][]const u8 = &.{},
    otherFlags: [][]const u8 = &.{},
    requiredFlags: [][]const u8 = &.{},
    overrideableFlags: [][]const u8 = &.{},

    /// Caller is responsible for freeing the ArrayList AND all of its members
    pub fn createFlagsArray(
        self: *const CppInfo,
        alloc: std.mem.Allocator,
    ) ![]const []const u8 {
        var ret: std.ArrayListUnmanaged([]const u8) = .empty;

        if (self.define) |define| {
            var iter = define.map.iterator();
            while (iter.next()) |v| {
                const val = v.value_ptr.* orelse continue;
                if (val.len == 0) {
                    try ret.append(
                        alloc,
                        try std.fmt.allocPrint(alloc, "-D{s}", .{v.key_ptr.*}),
                    );
                } else {
                    try ret.append(
                        alloc,
                        try std.fmt.allocPrint(
                            alloc,
                            "-D{s}={s}",
                            .{ v.key_ptr.*, val },
                        ),
                    );
                }
            }
        }

        for (self.include) |inc| {
            try ret.append(
                alloc,
                try std.fmt.allocPrint(alloc, "-I{s}", .{inc}),
            );
        }

        for (self.linkPath) |link| {
            try ret.append(
                alloc,
                try std.fmt.allocPrint(alloc, "-L{s}", .{link}),
            );
        }

        for (self.otherFlags) |flag| {
            try ret.append(
                alloc,
                try std.fmt.allocPrint(alloc, "{s}", .{flag}),
            );
        }

        return try ret.toOwnedSlice(alloc);
    }

    const ParsedFlag = struct {
        value: []const u8,
    };
    const Define = struct {
        name: []const u8,
        value: []const u8,
    };

    fn parseStartFlag(starts: []const u8, flag: []const u8) ?ParsedFlag {
        if (std.mem.startsWith(u8, flag, starts)) {
            return .{
                .value = flag[starts.len..],
            };
        }
        return null;
    }

    fn parseInclude(flag: []const u8) ?ParsedFlag {
        return parseStartFlag("-I", flag);
    }
    fn parseLinkPath(flag: []const u8) ?ParsedFlag {
        return parseStartFlag("-L", flag);
    }

    fn parseDefine(flag: []const u8) ?Define {
        if (!std.mem.startsWith(u8, flag, "-D")) {
            return null;
        }

        const rest = flag[2..];

        var split = std.mem.splitScalar(u8, rest, '=');
        return .{
            .name = split.next() orelse unreachable,
            .value = split.next() orelse "",
        };
    }

    pub fn flagOverrideable(self: *const CppInfo, flag: []const u8) ?usize {
        for (self.overrideableFlags, 0..) |f, i| {
            if (std.mem.startsWith(u8, flag, f)) {
                return i;
            }
        }
        return null;
    }

    pub fn flagRequired(self: *const CppInfo, flag: []const u8) ?usize {
        for (self.requiredFlags, 0..) |f, i| {
            if (std.mem.startsWith(u8, flag, f)) {
                return i;
            }
        }
        return null;
    }

    pub fn validateOverridesAndRequires(self: *const CppInfo) !void {
        for (self.overrideableFlags) |o| {
            if (std.mem.startsWith(u8, o, "-I")) {
                return error.IncludeFlagInOverrideableFlags;
            }
            if (std.mem.startsWith(u8, o, "-L")) {
                return error.LinkFlagInOverrideableFlags;
            }
        }
        for (self.requiredFlags) |o| {
            if (std.mem.startsWith(u8, o, "-I")) {
                return error.IncludeFlagInRequiredFlags;
            }
            if (std.mem.startsWith(u8, o, "-L")) {
                return error.LinkFlagInRequiredFlags;
            }
        }
    }

    pub fn addFlags(self: *CppInfo, alloc: std.mem.Allocator, flags: []const []const u8, diagnostic: *?[]const u8) !void {
        var requiredFlagsBitset: std.bit_set.DynamicBitSetUnmanaged = try .initFull(alloc, self.requiredFlags.len);
        defer requiredFlagsBitset.deinit(alloc);
        requiredFlagsBitset.unsetAll();

        var retOtherFlags: std.ArrayList([]const u8) = .empty;
        defer retOtherFlags.deinit(alloc);
        try retOtherFlags.appendSlice(alloc, self.otherFlags);

        for (flags) |flag| {
            const overrideable = self.flagOverrideable(flag);
            const required = self.flagRequired(flag);

            if (overrideable == null and required == null) {
                continue;
            }

            if (required) |index| {
                requiredFlagsBitset.set(index);
            }

            // two cases:
            //
            // 1. define: we just do a set no matter what
            // 2. not define:
            //  - if overrideable: we replace a value in the array, throw error if no matching value found
            //  - if just required: we append to array.
            if (parseDefine(flag)) |define| {
                if (overrideable != null) {
                    if (self.define == null) {
                        diagnostic.* = flag;
                        return error.OverrideableDefineFlagNotFound;
                    }
                    if (!self.define.?.hasKey(define.name)) {
                        diagnostic.* = flag;
                        return error.OverrideableDefineFlagNotFound;
                    }
                }
                self.define = self.define orelse .init(alloc);
                try self.define.?.set(define.name, define.value);
            } else {
                if (overrideable) |overrideIndex| {
                    const overrideFlag = self.overrideableFlags[overrideIndex];

                    for (self.otherFlags) |otherFlag| {
                        if (std.mem.startsWith(u8, otherFlag, overrideFlag)) {
                            break;
                        }
                    } else {
                        diagnostic.* = flag;
                        return error.OverrideableFlagNotFound;
                    }
                    retOtherFlags.items[overrideIndex] = flag;
                } else {
                    try retOtherFlags.append(alloc, flag);
                }
            }
        }

        // reverse the sets so that we can do a
        requiredFlagsBitset.toggleAll();
        while (requiredFlagsBitset.findFirstSet()) |i| {
            diagnostic.* = self.requiredFlags[i];
            return error.MissingRequiredFlag;
        }

        self.otherFlags = try retOtherFlags.toOwnedSlice(alloc);
    }
};

// This is the main type of a build object.
// The program should parse one of these into usable build instructions
pub const BuildInfo = struct {
    pub const FilesToCompile = enum {
        zig,
        cpp,
    };
    const defaultInclude = [_]FilesToCompile{ .zig, .cpp };

    pub const OutputType = enum {
        // builds a platformio.ini file that can be used by pio
        platformioini,
        // builds ONLY zig files into a libzig.a that can be linked by platformio
        libzig,
        // builds ALL files (c++ and zig) into a lib module that can be linked into
        // python modules or exes
        liball,
        // builds a python module
        pythonmodule,
        // builds a desktop executable
        exe,
    };
    const defaultOutput = [_]OutputType{ .libzig, .pythonmodule, .exe };

    pub const DependencyInfo = struct {
        importName: ?[]const u8,
        dependencyName: []const u8,
        // // potential solution to dependency loop problem
        // usage: ?enum {
        //     mainrepo,
        //     exeonly,
        //     pyonly,
        //     pyandexe,
        // },
    };

    pub const HeaderGenInfo = union(enum) {
        ignoreType: []const u8,
        addInclude: []const u8,
        ignoreDecl: []const u8,
    };

    pub const IdType = u8;

    pub const FieldEnum = std.meta.FieldEnum(@This());

    pub const KeysToInherit = [_]FieldEnum{
        .cpp,
        .target,
        .platformio,
        .dependencies,
        .outputTypes,
        .installHeaders,
        .headergen,
    };

    pub const InstallHeader = struct {
        fromDir: []const u8,
        toDir: []const u8,
    };

    __id: ?IdType = null,
    installHeaders: []InstallHeader = &.{},
    description: []const u8,
    cpp: CppInfo = .{},
    target: ?[]const u8 = null,
    headergen: []HeaderGenInfo = &.{},
    include: []const FilesToCompile = &defaultInclude,
    outputTypes: []const OutputType = &.{},
    platformio: ?PlatformIoInfo,
    optimize: ?std.builtin.OptimizeMode = null,
    inherit: ?[]const u8,
    dependencies: []DependencyInfo = &.{},

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        try zonParse.gigaPrintThing(self, 0, writer);
    }
};

pub const BuildDefaults = struct {
    mode: []const u8 = "desktop",
    targets: zonParse.Map(std.Target.Query.ParseOptions),
};

pub const ZonType = zonParse.Map(BuildInfo);
