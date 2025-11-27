const builtin = @import("builtin");
const std = @import("std");
pub const PythonInfo = struct {
    _include: ?[]const u8 = null,
    _lib: ?[]const u8 = null,
    _version: ?[]const u8 = null,
    _libName: ?[]const u8 = null,

    python_exe: []const u8,
    b: *std.Build,
    targetOs: std.Target.Os.Tag,

    pub fn getIncludePath(self: *PythonInfo) []const u8 {
        if (self._include) |i| return i;
        const pythonInc = getPythonIncludePath(
            self.python_exe,
            self.b.allocator,
        ) catch @panic("Missing python");
        self._include = pythonInc;
        return self._include.?;
    }
    pub fn getLibraryPath(self: *PythonInfo) []const u8 {
        if (self._lib) |l| return l;
        const pythonLib = getPythonLibraryPath(
            self.python_exe,
            self.b.allocator,
        ) catch @panic("Missing python");

        self._lib = pythonLib;
        return self._lib.?;
    }
    pub fn getLdVersion(self: *PythonInfo) []const u8 {
        if (self._version) |v| return v;
        self._version = getPythonLDVersion(
            self.python_exe,
            self.b.allocator,
            self.targetOs,
        ) catch @panic("Missing python");
        return self._version.?;
    }
    pub fn getLibName(self: *PythonInfo) []const u8 {
        if (self._libName) |l| return l;
        const pythonLibName = std.fmt.allocPrint(
            self.b.allocator,
            "python{s}",
            .{self.getLdVersion()},
        ) catch @panic("Missing python");
        self._libName = pythonLibName;
        return self._libName.?;
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

    // std.debug.print("{s}\n{s}\n{s}\n{s}\n", .{ pythonInc, pythonLib, pythonVer, pythonLibName });

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
