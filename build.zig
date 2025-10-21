const std = @import("std");

const compatHeadersDir = @import("src/chicot.zig").compatHeadersDir;

pub const chicotBuild = @import("src/chicot.zig").build;

pub fn build(b: *std.Build) !void {
    // try chicotFullBuild(b);
    const helpers = b.addModule("helpers", .{
        .root_source_file = b.path("src/helpers/root.zig"),
        .optimize = .Debug,
        .target = b.resolveTargetQuery(.{}),
    });

    const lib = b.addLibrary(.{
        .name = "helpers",
        .linkage = .static,
        .root_module = helpers,
    });
    b.installArtifact(lib);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const writeStep = b.addWriteFiles();
    // const path = writeStep.add("asdg", "ooga");
    // path.addStepDependencies(other_step: *Step)
    const emptyMod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = writeStep.add(
            "headerroot.zig",
            "pub fn donotusethisfunction() void {}",
        ),
    });
    const platformioClangdCompatHeaders = b.addLibrary(.{
        .name = compatHeadersDir,
        .linkage = .static,
        .root_module = emptyMod,
    });
    platformioClangdCompatHeaders.installHeadersDirectory(
        b.path("platformio_clangd"),
        compatHeadersDir,
        .{},
    );
    b.installArtifact(platformioClangdCompatHeaders);
}
