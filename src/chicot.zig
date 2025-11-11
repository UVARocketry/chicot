const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const zonParse = @import("helpers/parseZon.zig");
const steps = @import("./steps.zig");
const buildInfo = @import("helpers/buildInfo.zig");
const inherit = @import("helpers/inherit.zig");

const ZonType = buildInfo.ZonType;
const BuildDefaults = buildInfo.BuildDefaults;
const BuildInfo = buildInfo.BuildInfo;

pub const version = "0.0.0";

pub const mainDir = "src";
pub const desktopDir = "desktop";
pub const pyDir = "python";

pub const PythonInfo = struct {
    include: []const u8,
    lib: []const u8,
    version: []const u8,
    libName: []const u8,
};

pub fn getPythonInfo(b: *std.Build, pythonExe: ?[]const u8) PythonInfo {
    const python_exe =
        pythonExe orelse
        b.option([]const u8, "python-exe", "Python executable to use") orelse
        "python";

    const pythonInc = getPythonIncludePath(python_exe, b.allocator) catch @panic("Missing python");
    const pythonLib = getPythonLibraryPath(python_exe, b.allocator) catch @panic("Missing python");
    const pythonVer = getPythonLDVersion(python_exe, b.allocator) catch @panic("Missing python");
    const pythonLibName = std.fmt.allocPrint(b.allocator, "python{s}", .{pythonVer}) catch @panic("Missing python");
    // std.debug.print("{s}\n{s}\n{s}\n{s}\n", .{ pythonInc, pythonLib, pythonVer, pythonLibName });

    return .{
        .include = pythonInc,
        .lib = pythonLib,
        .version = pythonVer,
        .libName = pythonLibName,
    };
}

pub const Modules = struct {
    libzig: *std.Build.Step.Compile,
    libzigMod: *std.Build.Module,
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

pub fn createModulesAndLibs(
    b: *std.Build,
    resolvedInfo: FullBuildInfo,
    chicot: *std.Build.Dependency,
    rootDir: []const u8,
    projectName: []const u8,
    pyInfo: PythonInfo,
) !Modules {
    const rootZig = fileExists(b, mainDir, "root.zig");
    const pyrootZig = fileExists(b, pyDir, "python.zig");
    const desktopZig = fileExists(b, desktopDir, "main.zig");

    const writeStep = b.addWriteFiles();
    const emptyFile = writeStep.add(
        "headerroot.zig",
        "pub fn donotusethisfunction() void {}",
    );

    const target = resolvedInfo.target;
    const optimize = resolvedInfo.optimize;
    const cppInfo = resolvedInfo.buildInfo.cpp;

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

    const rootSrcDirs: [2][]const u8 = .{ rootDir, mainDir };

    const rootMod = b.addModule("root", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = emptyFile,
    });
    try addCppFiles(b, rootMod, b.pathJoin(&rootSrcDirs), cppInfo.otherFlags);
    resolveCppInfo(b, rootMod, cppInfo);

    // TODO: add libcpp so that parent dependencies can use cpp stuff from child
    // dependencies. then prolly js add it as a namedLazyPath
    // const libCpp = b.addLibrary(.{
    //     .name = "cpp",
    //     .linkage = .static,
    //     .root_module = rootMod,
    // });

    const pythonMod = if (dirExists(b, pyDir)) blk: {
        const pythonMod = b.addModule("python", .{
            .root_source_file = pyrootZig,
            .target = target,
            .optimize = optimize,
        });
        pythonMod.addImport(projectName, libzigMod);
        pythonMod.addIncludePath(b.path(b.pathJoin(&rootSrcDirs)));
        pythonMod.addIncludePath(.{ .cwd_relative = pyInfo.include });
        pythonMod.addLibraryPath(.{ .cwd_relative = pyInfo.lib });
        const rootPythonDirs: [2][]const u8 = .{ rootDir, pyDir };
        try addCppFiles(b, pythonMod, b.pathJoin(&rootPythonDirs), cppInfo.otherFlags);
        try addCppFiles(b, pythonMod, b.pathJoin(&rootSrcDirs), cppInfo.otherFlags);
        resolveCppInfo(b, pythonMod, cppInfo);
        break :blk pythonMod;
    } else null;

    const exeMod = if (dirExists(b, desktopDir)) blk: {
        const exeMod = b.addModule("main", .{
            .root_source_file = desktopZig,
            .target = target,
            .optimize = optimize,
        });
        exeMod.addIncludePath(b.path(b.pathJoin(&rootSrcDirs)));
        const rootDesktopDirs: [2][]const u8 = .{ rootDir, desktopDir };
        try addCppFiles(b, exeMod, b.pathJoin(&rootDesktopDirs), cppInfo.otherFlags);
        try addCppFiles(b, exeMod, b.pathJoin(&rootSrcDirs), cppInfo.otherFlags);
        resolveCppInfo(b, exeMod, cppInfo);

        break :blk exeMod;
    } else null;

    // const path = writeStep.add("asdg", "ooga");
    // path.addStepDependencies(other_step: *Step)
    const emptyMod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = emptyFile,
    });

    const zigObj = b.addObject(.{
        .name = "zig",
        .root_module = libzigMod,
    });

    const libzig = b.addLibrary(.{
        .name = "zig",
        .linkage = .static,
        .root_module = libzigMod,
    });
    libzig.link_gc_sections = false;

    const headerLib = b.addLibrary(.{
        .name = "headers",
        .linkage = .static,
        .root_module = emptyMod,
    });
    headerLib.installHeadersDirectory(b.path(mainDir), "", .{});

    const depHeadersDir = "depheaders";
    const depHeaderLib = b.addLibrary(.{
        .name = depHeadersDir,
        .linkage = .static,
        .root_module = emptyMod,
    });

    const lib = b.addLibrary(.{
        .name = projectName,
        .linkage = .static,
        .root_module = libzigMod,
    });
    lib.linkLibCpp();

    const python = if (pythonMod) |mod| blk: {
        const python = b.addLibrary(.{
            .name = "python",
            .linkage = .dynamic,
            .root_module = mod,
        });
        python.linkLibCpp();
        python.linkSystemLibrary(pyInfo.libName);

        break :blk python;
    } else null;

    const exe = if (exeMod) |mod| blk: {
        const exe = b.addExecutable(.{
            .name = projectName,
            .root_module = mod,
        });
        exe.linkLibCpp();
        exe.linkLibrary(libzig);
        break :blk exe;
    } else null;

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
        const dep = b.dependency(depInfo.dependencyName, .{
            .mode = @tagName(resolvedInfo.buildType),
            .__flagsFromRoot = rootFlags,
            .__flagsFromParent = parentFlags,
            .target = target,
            .optimize = optimize,
        });

        const depLibZigMod = dep.module(depInfo.dependencyName);
        const depLibZigObj = dep.namedLazyPath("obj/zig.o");
        const headers = dep.artifact("headers");

        const headersTree = headers.getEmittedIncludeTree();

        // rootMod.addImport(depInfo.importName orelse depInfo.dependencyName, mainMod);
        // rootMod.addIncludePath(headersTree);
        if (pythonMod) |mod| {
            mod.addImport(depInfo.importName orelse depInfo.dependencyName, depLibZigMod);
            mod.addIncludePath(headersTree);
        }

        if (exeMod) |mod| {
            // mod.addImport(depInfo.importName orelse depInfo.dependencyName, depLibZigMod);
            mod.addIncludePath(headersTree);
        }
        depHeaderLib.installHeadersDirectory(headersTree, depHeadersDir, .{});

        libzigMod.addImport(
            depInfo.importName orelse depInfo.dependencyName,
            depLibZigMod,
        );
        // std.debug.print("Adding object and stuff for {s}!\n", .{depInfo.dependencyName});
        libzig.addObjectFile(depLibZigObj);
    }
    return .{
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
        // .rootMod = rootMod,
        .libzigMod = libzigMod,
        .zigobject = zigObj,
    };
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
    };
}

const BuildOptions = struct {};

pub fn build(
    b: *std.Build,
    chicot: *std.Build.Dependency,
    zon: anytype,
    options: BuildOptions,
) !Modules {
    _ = options;
    const start = std.time.microTimestamp();
    defer {
        const end = std.time.microTimestamp();
        std.debug.print("Resolution time: {}ms\n", .{@divFloor(end - start, 1000)});
    }
    const projectName = @tagName(zon.name);

    const resolvedInfo = try resolveBuildInformation(b, zon);

    const rootDir = ".";

    const pyInfo = getPythonInfo(b, null);

    const pioDiffMode = b.option(
        bool,
        "diff",
        "Whether to diff the generated platformio.ini with the current platformio.ini script",
    ) orelse false;

    const modules = try createModulesAndLibs(
        b,
        resolvedInfo,
        chicot,
        rootDir,
        projectName,
        pyInfo,
    );

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

    const helpers = chicot.module("helpers");

    try steps.addLibraryJsonStep(b, chicot, helpers);

    try steps.addPioLspStep(
        b,
        helpers,
        chicot,
        pioProgramName,
        resolvedInfo.selectedMode,
        modules.depHeadersDir,
        modules.compatHeadersDir,
    );

    try steps.addDesktopLspStep(
        b,
        helpers,
        chicot,
        pioProgramName,
        resolvedInfo.selectedMode,
        pyInfo.include,
        modules.depHeadersDir,
        modules.platformioClangdCompatHeaders,
    );

    try steps.addPlatformioIniStep(b, helpers, chicot, pioDiffMode, b.allocator);

    const check = b.step("check", "Check if foo compiles");

    const outputTypes = resolvedInfo.buildInfo.outputTypes;
    if (std.mem.containsAtLeastScalar(
        BuildInfo.OutputType,
        outputTypes,
        1,
        .liball,
    )) {
        // std.debug.print("Installing liball!\n", .{});
        b.installArtifact(modules.lib);
        check.dependOn(&modules.lib.step);
    }
    b.installArtifact(modules.headerLib);
    b.installArtifact(modules.depHeaderLib);
    if (resolvedInfo.buildInfo.platformio != null) {
        b.installArtifact(modules.platformioClangdCompatHeaders);
    }
    b.addNamedLazyPath("obj/zig.o", modules.zigobject.getEmittedBin());
    if (std.mem.containsAtLeastScalar(
        BuildInfo.OutputType,
        outputTypes,
        1,
        .libzig,
    )) {
        // std.debug.print("Installing libzig!\n", .{});
        b.installArtifact(modules.libzig);
        check.dependOn(&modules.libzig.step);
        // b.installArtifact(modules.zigobject);
        // check.dependOn(&modules.zigobject.step);
    }
    if (std.mem.containsAtLeastScalar(
        BuildInfo.OutputType,
        outputTypes,
        1,
        .pythonmodule,
    )) {
        // std.debug.print("Installing py!\n", .{});
        if (modules.python) |py| {
            b.installArtifact(py);
            check.dependOn(&py.step);
            const name =
                try std.fmt.allocPrint(b.allocator, "python/lib{s}.so", .{projectName});
            std.debug.print("Installing {s}\n", .{name});

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
    )) {
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
    )) {
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
    info: BuildInfo.CppInfo,
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

/// Returns the include path for the Python.h files for building the python modules.
/// REQUIRES python to be installed
fn getPythonIncludePath(
    python_exe: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const includeResult = try runProcess(.{
        .allocator = allocator,
        .argv = &.{
            python_exe,
            "-c",
            "import sysconfig; print(sysconfig.get_path('include'), end='')",
        },
    });
    defer allocator.free(includeResult.stderr);
    return includeResult.stdout;
}

/// Returns the path for the python lib to be linked into the python modules.
/// REQUIRES python to be installed
fn getPythonLibraryPath(
    python_exe: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const includeResult = try runProcess(.{
        .allocator = allocator,
        .argv = &.{
            python_exe,
            "-c",
            "import sysconfig; print(sysconfig.get_config_var('LIBDIR'), end='')",
        },
    });
    defer allocator.free(includeResult.stderr);
    return includeResult.stdout;
}

/// Returns the version of the python program installed.
/// REQUIRES python to be installed
fn getPythonLDVersion(python_exe: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    // yes because of course windows does something different
    const getLdVersion = if (builtin.os.tag == .windows)
        "import sys; print(f'{sys.version_info.major}{sys.version_info.minor}', end='')"
    else
        "import sysconfig; print(sysconfig.get_config_var('LDVERSION'), end='')";

    const includeResult = try runProcess(.{
        .allocator = allocator,
        .argv = &.{
            python_exe,
            "-c",
            getLdVersion,
        },
    });
    defer allocator.free(includeResult.stderr);
    return includeResult.stdout;
}

const runProcess =
    if (builtin.zig_version.minor >= 12)
        std.process.Child.run
    else
        std.process.Child.exec;
