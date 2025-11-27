const builtin = @import("builtin");
const std = @import("std");
var _include: ?[]const u8 = null;
var _lib: ?[]const u8 = null;
var _version: ?[]const u8 = null;
var _libName: ?[]const u8 = null;
pub const PythonInfo = struct {
    python_exe: []const u8,
    b: *std.Build,
    targetOs: std.Target.Os.Tag,

    pub fn getIncludePath(self: *PythonInfo) []const u8 {
        if (_include) |i| return i;
        const pythonInc = getPythonIncludePath(
            self.python_exe,
            self.b.allocator,
        ) catch @panic("Missing python");
        _include = pythonInc;
        return _include.?;
    }
    pub fn getLibraryPath(self: *PythonInfo) []const u8 {
        if (_lib) |l| return l;
        const pythonLib = getPythonLibraryPath(
            self.python_exe,
            self.b.allocator,
        ) catch @panic("Missing python");

        _lib = pythonLib;
        return _lib.?;
    }
    pub fn getLdVersion(self: *PythonInfo) []const u8 {
        if (_version) |v| return v;
        _version = getPythonLDVersion(
            self.python_exe,
            self.b.allocator,
            self.targetOs,
        ) catch @panic("Missing python");
        return _version.?;
    }
    pub fn getLibName(self: *PythonInfo) []const u8 {
        if (_libName) |l| return l;
        const pythonLibName = std.fmt.allocPrint(
            self.b.allocator,
            "python{s}",
            .{self.getLdVersion()},
        ) catch @panic("Missing python");
        _libName = pythonLibName;
        return _libName.?;
    }
};

pub fn getPythonInfo(
    b: *std.Build,
    pythonExe: ?[]const u8,
    targetOs: std.Target.Os.Tag,
) PythonInfo {
    const python_exe =
        pythonExe orelse
        b.option([]const u8, "python-exe", "Python executable to use") orelse
        "python";

    return .{
        .b = b,
        .python_exe = python_exe,
        .targetOs = targetOs,
    };
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
fn getPythonLDVersion(
    python_exe: []const u8,
    allocator: std.mem.Allocator,
    targetOs: std.Target.Os.Tag,
) ![]const u8 {
    // yes because of course windows does something different
    const getLdVersion = if (targetOs == .windows)
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
