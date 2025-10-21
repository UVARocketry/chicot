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
    };

    pub const IdType = u8;

    pub const FieldEnum = std.meta.FieldEnum(@This());

    pub const KeysToInherit = [_]FieldEnum{
        .cpp,
        .target,
        .platformio,
        .dependencies,
        .outputTypes,
    };

    pub const CppInfo = struct {
        define: ?zonParse.Map(?[]const u8) = null,
        include: [][]const u8 = &.{},
        link: [][]const u8 = &.{},
        otherFlags: [][]const u8 = &.{},
    };

    __id: ?IdType = null,
    description: []const u8,
    cpp: CppInfo = .{},
    target: ?[]const u8 = null,
    // noinherit: []FieldEnum,
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
    mode: []const u8 = "platformio",
    targets: zonParse.Map(std.Target.Query.ParseOptions),
};

pub const ZonType = zonParse.Map(BuildInfo);
