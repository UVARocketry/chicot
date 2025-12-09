const std = @import("std");
const wine = @import("./wine.zig");
const builtin = @import("builtin");
const assert = std.debug.assert;

const zonParse = @import("helpers/parseZon.zig");
const Py = @import("./python.zig");
const steps = @import("./steps.zig");
const buildInfo = @import("helpers/buildInfo.zig");
const inherit = @import("helpers/inherit.zig");

const ZonType = buildInfo.ZonType;
const BuildDefaults = buildInfo.BuildDefaults;
const BuildInfo = buildInfo.BuildInfo;
const CppInfo = buildInfo.CppInfo;

pub const version = "0.0.0";

pub const mainDir = "src";
pub const desktopDir = "desktop";
pub const pyDir = "python";

pub const Modules = struct {
    libzig: *std.Build.Step.Compile,
    libzigMod: *std.Build.Module,
    libcpp: *std.Build.Step.Compile,
    libcppForDeps: *std.Build.Step.Compile,
    depLibcpps: []*std.Build.Step.Compile,
    depLibzigs: []*std.Build.Step.Compile,
    rootTests: ?*std.Build.Step.Compile,
    cppMod: *std.Build.Module,
    zigobject: *std.Build.Step.Compile,
    compatHeadersDir: []const u8,
    depHeadersDir: []const u8,
    platformioClangdCompatHeaders: *std.Build.Step.Compile,
    // rootMod: ?*std.Build.Module,
    lib: *std.Build.Step.Compile,
    headerLib: *std.Build.Step.Compile,
    depHeaderLib: *std.Build.Step.Compile,
    pythonMod: ?*std.Build.Module,
    python: ?*std.Build.Step.Compile,
    exeMod: ?*std.Build.Module,
    exe: ?*std.Build.Step.Compile,
};

pub const compatHeadersDir = "platformio-clangd-compat-headers";
const headerExtensions: []const []const u8 = &.{ "hpp", "h", "hh", "" };
const headerExcludeExtensions: []const []const u8 = &.{ "cc", "cpp", "c", "zig" };

pub fn getZigName(
    b: *std.Build,
    prefix: []const u8,
    name: []const u8,
    postfix: []const u8,
) []const u8 {
    return std.fmt.allocPrint(
        b.allocator,
        "{s}zig-{s}{s}",
        .{ prefix, name, postfix },
    ) catch unreachable;
}

pub fn createModulesAndLibs(
    b: *std.Build,
    zon: anytype,
    resolvedInfo: FullBuildInfo,
    chicot: *std.Build.Dependency,
    rootDir: []const u8,
    projectName: []const u8,
    pyInfo: *Py.PythonInfo,
) !Modules {
    const rootZig = fileExists(b, mainDir, "root.zig");
    const pyrootZig = fileExists(b, pyDir, "python.zig");
    const pyModIsZig = pyrootZig != null;
    const desktopZig = fileExists(b, desktopDir, "main.zig");
    const altDesktopZig = fileExists(b, mainDir, "main.zig");
    const exeIsZig = desktopZig != null or altDesktopZig != null;

    const target = resolvedInfo.target;
    const optimize = resolvedInfo.optimize;
    const cppInfo = resolvedInfo.buildInfo.cpp;

    const writeStep = b.addWriteFiles();
    const emptyFile = writeStep.add(
        "headerroot.zig",
        "pub fn donotusethisfunction() void {}",
    );

    // An empty module to replace some modules lowkey
    const emptyMod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = emptyFile,
    });

    // The module from root.zig
    const libzigMod = blk: {
        const info: std.Build.Module.CreateOptions = if (resolvedInfo.buildType == .teensy41) .{
            .root_source_file = rootZig orelse emptyFile,
            .target = target,
            .optimize = optimize,
            // these all shrink down the exe size
            .error_tracing = false,
            .omit_frame_pointer = true,
            // .strip = true,
            .stack_check = false,
            .stack_protector = false,
            .single_threaded = true,
            // this is ABSOLUTELY NECESSARY, otherwise linking will fail (i think)
            .unwind_tables = .none,
        } else .{
            .root_source_file = rootZig orelse emptyFile,
            .target = target,
            .optimize = optimize,
        };
        break :blk b.addModule(projectName, info);
    };

    const libzig = b.addLibrary(.{
        .name = getZigName(b, "", projectName, ""),
        .linkage = .static,
        .root_module = libzigMod,
    });

    const rootSrcDirs: [2][]const u8 = .{ rootDir, mainDir };

    // The module that contains all cpp files inside src/
    const cppMod = b.addModule("root", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = emptyFile,
    });
    if (dirExists(b, b.pathJoin(&rootSrcDirs))) {
        try addCppFiles(b, cppMod, b.pathJoin(&rootSrcDirs), cppInfo.otherFlags);
        resolveCppInfo(b, cppMod, cppInfo);
        resolveCppInfo(b, libzigMod, cppInfo);
    }

    // A library that links in all the libcpp's from sub dependencies
    const libCppForDeps = b.addLibrary(.{
        .name = "cpp",
        .linkage = .static,
        .root_module = emptyMod,
    });

    // A library that contains this library's libcpp and links all dependency libcpp's
    const libcpp = b.addLibrary(.{
        .name = "cpp",
        .linkage = .static,
        .root_module = cppMod,
    });
    libcpp.linkLibCpp();

    // A module that contains the python/* and also compiles python/python.zig if
    // it exists
    const pythonMod = if (dirExists(b, pyDir) and resolvedInfo.buildEverything) blk: {
        const pythonMod = b.addModule("python", .{
            .root_source_file = pyrootZig,
            .target = target,
            .optimize = optimize,
        });
        if (pyModIsZig) {
            pythonMod.addImport(projectName, libzigMod);
        }
        pythonMod.addIncludePath(b.path(b.pathJoin(&rootSrcDirs)));
        pythonMod.addIncludePath(.{ .cwd_relative = try wine.optionallyConvertWinePath(
            b.allocator,
            pyInfo.getIncludePath(),
            resolvedInfo.target.result.os.tag,
        ) });
        pythonMod.addLibraryPath(.{ .cwd_relative = try wine.optionallyConvertWinePath(
            b.allocator,
            pyInfo.getLibraryPath(),
            resolvedInfo.target.result.os.tag,
        ) });
        pythonMod.linkLibrary(libcpp);
        pythonMod.linkLibrary(libzig);
        pythonMod.linkLibrary(libCppForDeps);
        pythonMod.linkSystemLibrary(try wine.optionallyConvertWinePath(
            b.allocator,
            pyInfo.getLibName(),
            resolvedInfo.target.result.os.tag,
        ), .{});
        const rootPythonDirs: [2][]const u8 = .{ rootDir, pyDir };
        recursivelyAddIncludeDirs(b, pythonMod, b.pathJoin(&rootPythonDirs));
        try addCppFiles(b, pythonMod, b.pathJoin(&rootPythonDirs), cppInfo.otherFlags);
        // try addCppFiles(b, pythonMod, b.pathJoin(&rootSrcDirs), cppInfo.otherFlags);
        resolveCppInfo(b, pythonMod, cppInfo);
        break :blk pythonMod;
    } else null;

    // A module that contains the desktop/* and also compiles desktop/main.zig if
    // it exists
    const exeMod = if (dirExists(b, desktopDir) and resolvedInfo.buildEverything) blk: {
        const exeMod = b.addModule("main", .{
            .root_source_file = desktopZig orelse altDesktopZig,
            .target = target,
            .optimize = optimize,
        });
        if (altDesktopZig == null and exeIsZig) {
            exeMod.addImport(projectName, libzigMod);
        }
        exeMod.addIncludePath(b.path(b.pathJoin(&rootSrcDirs)));
        exeMod.linkLibrary(libcpp);
        exeMod.linkLibrary(libzig);
        exeMod.linkLibrary(libCppForDeps);
        const rootDesktopDirs: [2][]const u8 = .{ rootDir, desktopDir };
        recursivelyAddIncludeDirs(b, exeMod, b.pathJoin(&rootDesktopDirs));
        try addCppFiles(b, exeMod, b.pathJoin(&rootDesktopDirs), cppInfo.otherFlags);
        // try addCppFiles(b, exeMod, b.pathJoin(&rootSrcDirs), cppInfo.otherFlags);
        resolveCppInfo(b, exeMod, cppInfo);

        break :blk exeMod;
    } else null;

    // An object that builds libzigMod if it exists
    const zigObj = b.addObject(.{
        .name = getZigName(b, "", projectName, ""),
        .root_module = libzigMod,
    });

    // A lib for this lib's headers to be installed
    const headerLib = b.addLibrary(.{
        .name = "headers",
        .linkage = .static,
        .root_module = emptyMod,
    });
    cppMod.linkLibrary(headerLib);
    recursivelyAddHeaderDirs(b, headerLib, mainDir, "");
    for (resolvedInfo.buildInfo.installHeaders) |installDir| {
        recursivelyAddHeaderDirs(b, headerLib, installDir.fromDir, installDir.toDir);
    }

    // a lib for all dep's headers to be installed
    const depHeadersDir = "depheaders";
    const depHeaderLib = b.addLibrary(.{
        .name = depHeadersDir,
        .linkage = .static,
        .root_module = emptyMod,
    });

    // this makes it so that gd on an @cInclude on a c header path inside the current
    // project jumps to a file inside the current project *NOT* somewhere in the cache
    libzigMod.addIncludePath(b.path("src"));

    const lib = b.addLibrary(.{
        .name = projectName,
        .linkage = .static,
        .root_module = libzigMod,
    });
    // lib.linkLibrary(libzig);
    // lib.linkLibrary(libcpp);
    // lib.linkLibrary(libCppForDeps);
    // lib.linkLibCpp();

    // the python library
    const python = if (pythonMod) |mod| blk: {
        const python = b.addLibrary(.{
            .name = "python",
            .linkage = .dynamic,
            .root_module = mod,
        });
        python.linkLibCpp();

        break :blk python;
    } else null;

    // the exe
    const exe = if (exeMod) |mod| blk: {
        const exe = b.addExecutable(.{
            .name = projectName,
            .root_module = mod,
        });
        exe.linkLibCpp();
        break :blk exe;
    } else null;

    cppMod.linkLibrary(depHeaderLib);

    var libcpps: std.ArrayList(*std.Build.Step.Compile) = .empty;
    var libzigs: std.ArrayList(*std.Build.Step.Compile) = .empty;

    for (resolvedInfo.buildInfo.dependencies) |depInfo| {
        var rootFlags: []const []const u8 = undefined;
        var parentFlags: []const []const u8 = undefined;
        if (resolvedInfo.rootFlags) |r| {
            rootFlags = r;
            parentFlags = resolvedInfo.currentFlags;
        } else {
            rootFlags = resolvedInfo.currentFlags;
            parentFlags = &.{};
        }
        // std.debug.print("Loading dep {s} for {s}\n", .{ depInfo.dependencyName, projectName });
        const dep = b.dependency(depInfo.dependencyName, .{
            .mode = @tagName(resolvedInfo.buildType),
            .__flagsFromRoot = rootFlags,
            .dontBuildEverything = true,
            // .__spaceCount = spaceCount + 2,
            .__flagsFromParent = parentFlags,
            .target = target,
            .optimize = optimize,
        });

        const depLibZigMod = dep.module(depInfo.dependencyName);
        const depLibCpp =
            if (resolvedInfo.buildType == .desktop) blk: {
                const l = dep.artifact("cpp");
                libCppForDeps.root_module.linkLibrary(l);
                try libcpps.append(b.allocator, l);
                break :blk l;
            } else null;

        // OK so... FOR SOME REASON, when we are building for platformio,
        // we have to link all objects together and stuff,
        // but when we are building for python modules, it is better to link
        // in libzig
        const depLibZigObj =
            if (resolvedInfo.buildType == .teensy41)
                dep.namedLazyPath(getZigName(b, "obj/", depInfo.dependencyName, ".o"))
            else
                null;

        const depLibZig =
            if (resolvedInfo.buildType == .desktop) blk: {
                const l = dep.artifact(getZigName(b, "", depInfo.dependencyName, ""));
                try libzigs.append(b.allocator, l);
                break :blk l;
            } else null;
        const headers = dep.artifact("headers");
        const depsDepHeaders = dep.artifact("depheaders");

        const headersTree = headers.getEmittedIncludeTree();
        inline for (@typeInfo(@TypeOf(zon.dependencies)).@"struct".fields) |field| {
            const val = @field(zon.dependencies, field.name);
            if (std.mem.eql(u8, field.name, depInfo.dependencyName)) {
                if (@hasField(@TypeOf(val), "path")) {
                    libzigMod.addIncludePath(b.path(b.pathJoin(&.{ val.path, "src" })));
                } else {
                    libzigMod.addIncludePath(headersTree);
                }
            }
        }

        // actualLibCpp.addIncludePath(headersTree);
        cppMod.addIncludePath(headersTree);

        if (pythonMod) |mod| {
            mod.addImport(depInfo.importName orelse depInfo.dependencyName, depLibZigMod);
            mod.addIncludePath(headersTree);
            mod.linkLibrary(depLibCpp.?);
            // python.?.linkLibrary(depLibCpp.?);
        }

        if (exeMod) |mod| {
            // mod.addImport(depInfo.importName orelse depInfo.dependencyName, depLibZigMod);
            mod.addIncludePath(headersTree);
            mod.linkLibrary(depLibCpp.?);
        }
        depHeaderLib.installHeadersDirectory(headersTree, depHeadersDir, .{
            .include_extensions = headerExtensions,
            .exclude_extensions = headerExcludeExtensions,
        });
        depHeaderLib.installHeadersDirectory(
            depsDepHeaders.getEmittedIncludeTree(),
            "",
            .{
                .include_extensions = headerExtensions,
                .exclude_extensions = headerExcludeExtensions,
            },
        );
        libzigMod.addIncludePath(depsDepHeaders.getEmittedIncludeTree());

        libzigMod.addImport(
            depInfo.importName orelse depInfo.dependencyName,
            depLibZigMod,
        );
        // std.debug.print("Adding object and stuff for {s}!\n", .{depInfo.dependencyName});
        if (depLibZigObj) |d| {
            libzig.addObjectFile(d);
        }
        if (depLibZig) |d| {
            libzig.linkLibrary(d);
        }
    }

    // make sure libzig has the correct headers for everything
    libzigMod.addIncludePath(headerLib.getEmittedIncludeTree());
    // make sure zig files can see dependency headers

    const rootTests = if (resolvedInfo.buildType == .desktop) blk: {
        const rootTests = b.addTest(.{
            .root_module = libzigMod,
        });
        // link in essential cpp info
        rootTests.linkLibrary(libcpp);
        rootTests.linkLibrary(libCppForDeps);
        break :blk rootTests;
    } else null;

    return .{
        .rootTests = rootTests,
        .libcpp = libcpp,
        .cppMod = cppMod,
        .libzig = libzig,
        .compatHeadersDir = compatHeadersDir,
        .depHeadersDir = depHeadersDir,
        .platformioClangdCompatHeaders = chicot.artifact(compatHeadersDir),
        .lib = lib,
        .headerLib = headerLib,
        .depHeaderLib = depHeaderLib,
        .python = python,
        .exe = exe,
        .pythonMod = pythonMod,
        .exeMod = exeMod,
        .depLibzigs = libzigs.items,
        .depLibcpps = libcpps.items,
        // .rootMod = rootMod,
        .libzigMod = libzigMod,
        .zigobject = zigObj,
        .libcppForDeps = libCppForDeps,
    };
}

pub fn recursivelyAddIncludeDirs(
    b: *std.Build,
    lib: *std.Build.Module,
    origin: []const u8,
) void {
    if (!dirExists(b, origin)) {
        return;
    }

    var dir = b.build_root.handle.openDir(origin, .{
        .iterate = true,
    }) catch return;
    defer dir.close();

    lib.addIncludePath(b.path(origin));
    var iter = dir.iterate();
    while (iter.next() catch return) |v| {
        if (v.kind == .directory) {
            const newPath = b.pathJoin(&.{ origin, v.name });
            recursivelyAddIncludeDirs(b, lib, newPath);
        }
    }
}
pub fn recursivelyAddHeaderDirs(
    b: *std.Build,
    lib: *std.Build.Step.Compile,
    origin: []const u8,
    targetPath: []const u8,
) void {
    if (!dirExists(b, origin)) {
        return;
    }

    var dir = b.build_root.handle.openDir(origin, .{
        .iterate = true,
    }) catch return;
    defer dir.close();

    lib.installHeadersDirectory(b.path(origin), targetPath, .{
        .include_extensions = headerExtensions,
        .exclude_extensions = headerExcludeExtensions,
    });
    var iter = dir.iterate();
    while (iter.next() catch return) |v| {
        if (v.kind == .directory) {
            const newPath = b.pathJoin(&.{ origin, v.name });
            const newTarget = b.pathJoin(&.{ targetPath, v.name });
            recursivelyAddHeaderDirs(b, lib, newPath, newTarget);
        }
    }
}

pub fn makeBuildModeListString(alloc: std.mem.Allocator, thing: ZonType) ![]const u8 {
    var iter = thing.map.iterator();
    var keyList: std.SegmentedList([]const u8, 8) = .{};
    while (iter.next()) |v| {
        try keyList.append(alloc, v.key_ptr.*);
    }
    if (keyList.len == 0) {
        return "N/A";
    } else if (keyList.len == 1) {
        return try std.fmt.allocPrint(alloc, "'{s}'", .{keyList.at(0).*});
    } else if (keyList.len == 2) {
        return try std.fmt.allocPrint(
            alloc,
            "'{s}' or '{s}'",
            .{ keyList.at(0).*, keyList.at(1).* },
        );
    } else {
        var ret: []const u8 = "";
        for (0..keyList.len - 1) |i| {
            ret = try std.fmt.allocPrint(
                alloc,
                "{s}'{s}', ",
                .{ ret, keyList.at(i).* },
            );
        }
        ret = try std.fmt.allocPrint(
            alloc,
            "{s}or '{s}'",
            .{ ret, keyList.at(keyList.len - 1).* },
        );
        return ret;
    }
}

const FullBuildInfo = struct {
    buildInfo: BuildInfo,
    rootFlags: ?[]const []const u8,
    currentFlags: []const []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    buildType: enum { teensy41, desktop },
    selectedMode: []const u8,
    buildEverything: bool,
};

pub fn resolveBuildInformation(b: *std.Build, zon: anytype) !FullBuildInfo {
    // parse the entire buildmodes object
    var thing = zonParse.parseZonStruct(
        b.allocator,
        ZonType,
        zon.buildmodes,
        ".buildmodes",
    );

    // we force the desktop and teensy41 keys so that we can guarantee that subdeps
    // have these for building
    if (!thing.map.contains("desktop")) {
        std.debug.print(
            "ERROR: build.zig.zon .buildmodes MUST contain a `desktop` field!\n",
            .{},
        );
        return error.MissingDesktopKey;
    }

    if (!thing.map.contains("teensy41")) {
        std.debug.print(
            "ERROR: build.zig.zon .buildmodes MUST contain a `teensy41` field!\n",
            .{},
        );
        return error.MissingTeensy41Key;
    }

    try inherit.resolveInheritance(b.allocator, &thing);

    var defaults = zonParse.parseZonStruct(
        b.allocator,
        BuildDefaults,
        zon.builddefaults,
        ".builddefaults",
    );
    try defaults.targets.set("desktop", .{});

    const buildModeList = try makeBuildModeListString(b.allocator, thing);

    const mode = blk: {
        const currentStr: []const u8 = try std.fmt.allocPrint(
            b.allocator,
            "The mode to build the software in, can be one of: {s}",
            .{buildModeList},
        );
        break :blk b.option([]const u8, "mode", currentStr) orelse defaults.mode;
    };

    const dontBuildEverything = b.option(bool, "dontBuildEverything", "Whether to build everything specified by the zon file, or just items needed for parent deps") orelse false;

    if (!thing.hasKey(mode)) {
        @panic(try std.fmt.allocPrint(
            b.allocator,
            "Could not find build mode ('{s}') in the list of allowed build modes: {s}",
            .{ mode, buildModeList },
        ));
    }

    var modeInfo = thing.get(mode);

    const modeTarget = modeInfo.target orelse "desktop";

    if (!defaults.targets.hasKey(modeTarget)) {
        std.debug.print("Could not find target key '{s}' in allowed target list: \n", .{modeTarget});
        var iter = defaults.targets.map.iterator();
        while (iter.next()) |v| {
            std.debug.print("  - {s}\n", .{v.key_ptr.*});
        }
        return error.KeyNotFound;
    }

    const targetQuery: std.Target.Query.ParseOptions =
        defaults.targets.get(modeTarget);

    // basic target stuff.
    // Since the buildmodes stuff has a target option, then we use that as the default.
    // This is for not having to change the target when building for the teensy
    const target = b.standardTargetOptions(.{
        .default_target = try std.Target.Query.parse(targetQuery),
    });

    try inherit.resolveInheritance(b.allocator, &thing);

    const osName = @tagName(target.result.os.tag);

    const osMode = try std.fmt.allocPrint(b.allocator, "{s}_{s}", .{ mode, osName });

    if (thing.map.contains(osMode)) {
        thing.getPtr(mode).inherit = osMode;
    }

    try inherit.resolveInheritance(b.allocator, &thing);

    const rootFlags = b.option(
        []const []const u8,
        "__flagsFromRoot",
        "INTERNAL ONLY! The flags from the root dependency",
    );

    const parentFlags = b.option(
        []const []const u8,
        "__flagsFromParent",
        "INTERNAL ONLY! The flags from the parent dependency",
    );

    var diagnostic: ?[]const u8 = null;
    if (rootFlags != null and parentFlags != null) {
        var mergedFlags: std.ArrayList([]const u8) = .empty;
        defer mergedFlags.deinit(b.allocator);
        try mergedFlags.appendSlice(b.allocator, parentFlags.?);
        try mergedFlags.appendSlice(b.allocator, rootFlags.?);
        modeInfo.cpp.addFlags(b.allocator, mergedFlags.items, &diagnostic) catch |e| {
            if (diagnostic) |d| {
                std.debug.print("Referenced flags: {s}\n", .{d});
            }
            return e;
        };
    }

    // std.debug.print("cpp info: \n", .{});
    // std.debug.print("  include: \n", .{});
    // for (modeInfo.cpp.include) |inc| {
    //     std.debug.print("    - {s}\n", .{inc});
    // }
    // std.debug.print("  link:\n", .{});
    // for (modeInfo.cpp.linkPath) |link| {
    //     std.debug.print("    - {s}\n", .{link});
    // }
    // std.debug.print("  flags:\n", .{});
    // for (modeInfo.cpp.otherFlags) |flag| {
    //     std.debug.print("    {s}\n", .{flag});
    // }
    // if (modeInfo.cpp.define) |d| {
    //     var iter = d.map.iterator();
    //     std.debug.print("  define:\n", .{});
    //     while (iter.next()) |next| {
    //         std.debug.print("    {s} = {s}\n", .{ next.key_ptr.*, next.value_ptr.* orelse "UNDEFINED" });
    //     }
    // }

    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = modeInfo.optimize,
    });
    return .{
        .optimize = optimize,
        .target = target,
        .buildInfo = modeInfo,
        .currentFlags = try modeInfo.cpp.createFlagsArray(b.allocator),
        .rootFlags = rootFlags,
        .buildType = if (modeInfo.platformio) |_| .teensy41 else .desktop,
        .selectedMode = mode,
        .buildEverything = !dontBuildEverything,
    };
}

const BuildOptions = struct {};

// fn printSpaces(spaceCount: usize) void {
//     for (0..spaceCount) |_| {
//         std.debug.print(" ", .{});
//     }
// }

fn timestamp(name: []const u8, start: *i64) void {
    std.debug.print(
        "{s}: {}ms\n",
        .{ name, @divFloor(std.time.microTimestamp() - start.*, 1000) },
    );
    start.* = std.time.microTimestamp();
}

pub fn build(
    b: *std.Build,
    chicot: *std.Build.Dependency,
    zon: anytype,
    options: BuildOptions,
) !Modules {
    _ = options;
    // std.debug.print("PROJECT: {s}: {{\n", .{
    //     @tagName(zon.name),
    // });
    // defer std.debug.print("}}\n", .{});
    // const spaceCount = b.option(u8, "__spaceCount", "ooga") orelse 0;
    const start = std.time.microTimestamp();
    // _ = start;
    const timestampStart = std.time.microTimestamp();
    _ = timestampStart;
    defer {
        const end = std.time.microTimestamp();
        // _ = end;
        // timestamp("Install", &timestampStart);
        // printSpaces(spaceCount);
        std.debug.print("Resolution time: {}ms\n", .{@divFloor(end - start, 1000)});
    }
    const projectName = @tagName(zon.name);
    // printSpaces(spaceCount);
    // std.debug.print("Starting build for {s}\n", .{projectName});
    defer {
        // printSpaces(spaceCount);
        // std.debug.print("Ending build for {s}\n", .{projectName});
    }

    const resolvedInfo = try resolveBuildInformation(b, zon);

    // timestamp("Build resolution", &timestampStart);

    const rootDir = ".";

    var pyInfo = Py.getPythonInfo(b, null, resolvedInfo.target.result.os.tag);

    // timestamp("Python resolution", &timestampStart);

    const pioDiffMode = b.option(
        bool,
        "diff",
        "Whether to diff the generated platformio.ini with the current platformio.ini script",
    ) orelse false;

    const helpers = chicot.module("helpers");

    const modules = try createModulesAndLibs(
        b,
        zon,
        resolvedInfo,
        chicot,
        rootDir,
        projectName,
        &pyInfo,
        // spaceCount,
    );

    const emittedHeader = try steps.addHeaderGen(
        b,
        chicot,
        helpers,
        modules.libzigMod,
        resolvedInfo.selectedMode,
        b.install_prefix,
    );
    const headerGenStep = b.step(
        "header",
        "Emit a C/C++ header that exports all the symbols in the src/root.zig file",
    );
    const inst = b.addInstallFile(emittedHeader, try std.fmt.allocPrint(
        b.allocator,
        "zigheader.h",
        .{},
    ));
    headerGenStep.dependOn(&inst.step);

    if (modules.rootTests) |rootTests| {
        const runTests = b.addRunArtifact(rootTests);

        const testStep = b.step("test", "run tests");
        testStep.dependOn(&rootTests.step);
        testStep.dependOn(&runTests.step);
    }

    // timestamp("Module creation", &timestampStart);

    const pioProgramName = blk: {
        const pioProgramName =
            if (builtin.os.tag == .windows) "platformio.exe" else "platformio";

        const homeDirVar =
            if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";

        const homeDir = try std.process.getEnvVarOwned(b.allocator, homeDirVar);
        const binDir =
            if (builtin.os.tag == .windows) "Scripts" else "bin";
        const separator =
            if (builtin.os.tag == .windows) '\\' else '/';

        const expectedPioDir = try std.fmt.allocPrint(
            b.allocator,
            "{s}{c}penv{c}{s}",
            .{ homeDir, separator, separator, binDir },
        );

        // std.debug.print("searching at {s}!\n", .{expectedPioDir});
        const pio = try b.findProgram(&.{pioProgramName}, &.{expectedPioDir});
        // std.debug.print("found pio at {s}!\n", .{pio});
        break :blk pio;
    };

    try steps.addLibraryJsonStep(b, chicot, helpers);

    if (resolvedInfo.buildType == .teensy41) {
        try steps.addPioLspStep(
            b,
            helpers,
            chicot,
            pioProgramName,
            resolvedInfo.selectedMode,
            modules.depHeadersDir,
            modules.compatHeadersDir,
        );
    } else {
        try steps.addDesktopLspStep(
            b,
            helpers,
            chicot,
            pioProgramName,
            resolvedInfo.selectedMode,
            pyInfo.getIncludePath(),
            modules.depHeadersDir,
            modules.platformioClangdCompatHeaders,
        );
    }

    try steps.addPlatformioIniStep(b, helpers, chicot, pioDiffMode, b.allocator);

    // timestamp("Step creation", &timestampStart);

    const check = b.step("check", "Check if foo compiles");

    const outputTypes = resolvedInfo.buildInfo.outputTypes;

    if (resolvedInfo.buildType == .desktop) {
        b.installArtifact(modules.libcpp);
        check.dependOn(&modules.libcpp.step);
    }

    b.installArtifact(modules.headerLib);
    b.installArtifact(modules.depHeaderLib);
    b.addNamedLazyPath(getZigName(b, "obj/", projectName, ".o"), modules.zigobject.getEmittedBin());

    if (std.mem.containsAtLeastScalar(
        BuildInfo.OutputType,
        outputTypes,
        1,
        .liball,
    ) and resolvedInfo.buildEverything) {
        // std.debug.print("Installing liball!\n", .{});
        b.installArtifact(modules.lib);
        check.dependOn(&modules.lib.step);
    }
    if (resolvedInfo.buildInfo.platformio != null) {
        b.installArtifact(modules.platformioClangdCompatHeaders);
    }

    // if (std.mem.containsAtLeastScalar(
    //     BuildInfo.OutputType,
    //     outputTypes,
    //     1,
    //     .libzig,
    // ) and resolvedInfo.buildEverything) {
    // std.debug.print("Installing libzig!\n", .{});
    b.installArtifact(modules.libzig);
    check.dependOn(&modules.libzig.step);
    // b.installArtifact(modules.zigobject);
    // check.dependOn(&modules.zigobject.step);
    // }
    if (std.mem.containsAtLeastScalar(
        BuildInfo.OutputType,
        outputTypes,
        1,
        .pythonmodule,
    ) and resolvedInfo.buildEverything) {
        const forceBuildPy = b.option(
            bool,
            "forceBuildPy",
            "Whether to force building python modules (only matters if you are cross compiling",
        ) orelse false;
        const differentOs = resolvedInfo.target.result.os.tag != builtin.os.tag;
        const differentAbi = resolvedInfo.target.result.abi != builtin.abi;
        const differentCpu = resolvedInfo.target.result.cpu.arch != builtin.cpu.arch;
        const crossCompiling = differentOs or differentAbi or differentCpu;
        if (!forceBuildPy and crossCompiling) {
            std.debug.print(
                "Skipping python install because you are cross compiling!\n",
                .{},
            );
        } else if (modules.python) |py| {
            // std.debug.print("Installing py!\n", .{});
            b.installArtifact(py);
            check.dependOn(&py.step);
            const soExtension = if (resolvedInfo.target.result.os.tag == .windows)
                "pyd"
            else
                "so";

            const name = try std.fmt.allocPrint(
                b.allocator,
                "python/{s}.{s}",
                .{ projectName, soExtension },
            );
            // std.debug.print("Installing {s}\n", .{name});

            const pyStep = b.step("py", "Installs the python module to the canonical location");
            const step = b.addInstallFile(
                py.getEmittedBin(),
                name,
            );
            pyStep.dependOn(&step.step);
        } else {
            std.debug.print(
                "zon file directs chicot to install pythonmodule, but no pythonmodule was created during the build process. Did you forget to use the {s}/ folder?\n",
                .{pyDir},
            );
        }
    }
    if (std.mem.containsAtLeastScalar(
        BuildInfo.OutputType,
        outputTypes,
        1,
        .exe,
    ) and resolvedInfo.buildEverything) {
        // std.debug.print("Installing exe!\n", .{});
        if (modules.exe) |exe| {
            b.installArtifact(exe);
            check.dependOn(&exe.step);
        } else {
            std.debug.print(
                "zon file directs chicot to install an exe, but no exe was created during the build process. Did you forget to use the {s}/ folder?\n",
                .{desktopDir},
            );
        }
    }

    if (std.mem.containsAtLeastScalar(
        BuildInfo.OutputType,
        outputTypes,
        1,
        .exe,
    ) and resolvedInfo.buildEverything) {
        if (modules.exe) |exe| {
            const run_step = b.step("run", "Run the exe");

            const run_cmd = b.addRunArtifact(exe);
            run_step.dependOn(&run_cmd.step);

            run_cmd.step.dependOn(b.getInstallStep());

            // This allows the user to pass arguments to the application in the build
            // command itself, like this: `zig build run -- arg1 arg2 etc`
            if (b.args) |args| {
                run_cmd.addArgs(args);
            }
        }
    }
    return modules;
}

pub fn resolveCppInfo(
    b: *std.Build,
    lib: *std.Build.Module,
    info: CppInfo,
) void {
    for (info.include) |inc| {
        lib.addIncludePath(b.path(inc));
    }
    for (info.linkPath) |inc| {
        lib.linkSystemLibrary(inc, .{});
    }

    if (info.define) |d| {
        var iter = d.map.iterator();
        while (iter.next()) |v| {
            if (v.value_ptr.*) |val| {
                lib.addCMacro(v.key_ptr.*, val);
            }
        }
    }
}

pub fn addCppFiles(
    b: *std.Build,
    mod: *std.Build.Module,
    rootDir: []const u8,
    flags: []const []const u8,
) !void {
    var dir = try b.build_root.handle.openDir(rootDir, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();

    while (try iter.next()) |f| {
        if (f.kind == .directory) {
            const pathArr: [2][]const u8 = .{ rootDir, f.name };
            const path = try std.fs.path.join(b.allocator, &pathArr);
            defer b.allocator.free(path);
            try addCppFiles(b, mod, path, flags);
        } else if (f.kind == .file and std.mem.endsWith(u8, f.name, ".cpp")) {
            const paths: [2][]const u8 = .{ rootDir, f.name };
            mod.addCSourceFile(.{
                .file = b.path(b.pathJoin(&paths)),
                .flags = flags,
            });
        }
    }
}
pub fn dirExists(b: *std.Build, path: []const u8) bool {
    var dir = b.build_root.handle.openDir(path, .{}) catch return false;
    defer dir.close();
    return true;
}

pub fn fileExists(
    b: *std.Build,
    subDir: []const u8,
    path: []const u8,
) ?std.Build.LazyPath {
    var dir = b.build_root.handle.openDir(subDir, .{}) catch return null;
    defer dir.close();
    dir.access(path, .{}) catch return null;
    const array: [2][]const u8 = .{ subDir, path };
    return b.path(b.pathJoin(&array));
}
