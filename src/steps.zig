const std = @import("std");

pub fn getFileContents(
    dir: std.fs.Dir,
    name: []const u8,
    alloc: std.mem.Allocator,
    maxLen: usize,
) ![]const u8 {
    var buf = try alloc.alloc(u8, maxLen);
    errdefer alloc.free(buf);
    const file = try dir.openFile(name, .{});
    var reader = file.reader(&.{});
    const len = try reader.interface.readSliceShort(buf);
    if (len < buf.len) {
        if (alloc.resize(buf, len)) {
            buf = buf[0..len];
        } else {
            const newBuf = try alloc.alloc(u8, len);
            @memcpy(newBuf, buf[0..len]);
            alloc.free(buf);
            buf = newBuf;
        }
    }
    return buf;
}

pub fn addHeaderGen(
    b: *std.Build,
    chicot: *std.Build.Dependency,
    helpers: *std.Build.Module,
    libzigMod: *std.Build.Module,
    mode: []const u8,
    buildPrefix: []const u8,
) !std.Build.LazyPath {
    const headergenMod = b.addModule("headergen", .{
        .root_source_file = chicot.path("src/helpers/generators/headers.zig"),
        .optimize = .Debug,
        .target = b.graph.host,
    });
    headergenMod.addImport("helpers", helpers);
    headergenMod.addImport("mod", libzigMod);
    headergenMod.addAnonymousImport("zon", .{
        .root_source_file = b.path("build.zig.zon"),
    });

    const headergenProg = b.addExecutable(.{
        .name = "headergen",
        .root_module = headergenMod,
    });

    // b.installArtifact(pioIniProgram);
    const runHeadergen = b.addRunArtifact(headergenProg);

    const headerOut = runHeadergen.addOutputFileArg("zig.h");
    runHeadergen.addArg(mode);
    runHeadergen.addArg(buildPrefix);

    return headerOut;
}

pub fn addLibraryJsonStep(
    b: *std.Build,
    chicot: *std.Build.Dependency,
    helpers: *std.Build.Module,
) !void {
    const libraryJsonMod = b.addModule("libraryJson", .{
        .root_source_file = chicot.path("src/helpers/generators/libraryJson.zig"),
        .optimize = .Debug,
        .target = b.graph.host,
    });
    libraryJsonMod.addImport("helpers", helpers);
    libraryJsonMod.addAnonymousImport("zon", .{
        .root_source_file = b.path("build.zig.zon"),
    });

    const libraryJsonProg = b.addExecutable(.{
        .name = "pioini",
        .root_module = libraryJsonMod,
    });

    // b.installArtifact(pioIniProgram);
    const runLibraryJson = b.addRunArtifact(libraryJsonProg);

    const libraryJsonOut = runLibraryJson.addOutputFileArg("library.json");

    const installLibraryJson = b.addInstallFile(libraryJsonOut, "library.json");

    const libraryJsonStep = b.step("libraryjson", "generate the library.json for platformio to be able to use this repo as a dependency");
    libraryJsonStep.dependOn(&installLibraryJson.step);
}

pub fn addPioLspStep(
    b: *std.Build,
    helpers: *std.Build.Module,
    chicot: *std.Build.Dependency,
    pioProgramName: []const u8,
    mode: []const u8,
    depHeadersDir: []const u8,
    compatHeadersDir: []const u8,
) !void {
    const pioLspModule = b.createModule(.{
        .root_source_file = chicot.path("src/helpers/generators/pioLspInfo.zig"),
        .optimize = .Debug,
        .target = b.graph.host,
    });
    pioLspModule.addImport("helpers", helpers);
    pioLspModule.addAnonymousImport("zon", .{
        .root_source_file = b.path("build.zig.zon"),
    });

    const pioLspProgram = b.addExecutable(.{
        .name = "piolsp",
        .root_module = pioLspModule,
    });

    // b.installArtifact(pioIniProgram);
    const runPioLsp = b.addRunArtifact(pioLspProgram);

    runPioLsp.addArg(pioProgramName);
    runPioLsp.addArg(mode);
    runPioLsp.addArg(compatHeadersDir);
    runPioLsp.addArg(depHeadersDir);
    // runPioLsp.addFileArg(pioRoot);
    // runPioLsp.addFileArg(writeStep.add("main.cpp", "int main(){}\n\n"));
    const outputCompFlags = runPioLsp.addOutputFileArg("compile_flags.txt");
    // const outputCompCommands = runPioLsp.addOutputFileArg("compile_commands.json");
    // const outputCppProps = runPioLsp.addOutputFileArg(".vscode/c_cpp_properties.json");

    const installCompFlags = b.addInstallFile(outputCompFlags, "compile_flags.txt");
    // const installCompCommands = b.addInstallFile(outputCompCommands, "compile_commands.json");
    // const installCppProps = b.addInstallFile(outputCppProps, ".vscode/c_cpp_properties.json");

    b.installArtifact(pioLspProgram);

    const lsp = b.step("lsp", "generate the necessary info for your lsp to work");
    lsp.dependOn(&installCompFlags.step);
    // lsp.dependOn(&platformioClangdCompatHeaders.step);
    // lsp.dependOn(&installCompCommands.step);
    // lsp.dependOn(&installCppProps.step);
}

pub fn addDesktopLspStep(
    b: *std.Build,
    helpers: *std.Build.Module,
    chicot: *std.Build.Dependency,
    pioProgramName: []const u8,
    mode: []const u8,
    pythonInc: []const u8,
    depHeadersDir: []const u8,
    platformioClangdCompatHeaders: *std.Build.Step.Compile,
) !void {
    const lspModule = b.createModule(.{
        .root_source_file = chicot.path("src/helpers/generators/desktopLspInfo.zig"),
        .optimize = .Debug,
        .target = b.graph.host,
    });
    lspModule.addImport("helpers", helpers);
    lspModule.addAnonymousImport("zon", .{
        .root_source_file = b.path("build.zig.zon"),
    });

    const lspProgram = b.addExecutable(.{
        .name = "lsp",
        .root_module = lspModule,
    });

    // b.installArtifact(pioIniProgram);
    const runLsp = b.addRunArtifact(lspProgram);

    // keep this in here just in case we merge pioLspInfo and desktopLspInfo
    runLsp.addArg(pioProgramName);
    runLsp.addArg(mode);
    runLsp.addArg(pythonInc);
    runLsp.addArg(depHeadersDir);
    // TODO: pass the os we are building for so that it can inherit desktop_{os}
    // info properly

    // keep this in here just in case we merge pioLspInfo and desktopLspInfo
    runLsp.addDirectoryArg(platformioClangdCompatHeaders.getEmittedIncludeTree());
    const outputCompFlags = runLsp.addOutputFileArg("compile_flags.txt");
    // const outputCppProps = runLsp.addOutputFileArg(".vscode/c_cpp_properties.json");
    // TODO: detect missing cppprops, and replace with empty thing
    // runLsp.addFileArg(b.path(".vscode/c_cpp_properties.json"));

    const installCompFlags = b.addInstallFile(outputCompFlags, "compile_flags.txt");
    // const installCppProps = b.addInstallFile(
    //     outputCppProps,
    //     ".vscode/c_cpp_properties.json",
    // );

    b.installArtifact(lspProgram);

    const lsp = b.step("lsp", "generate the necessary info for your lsp to work");
    lsp.dependOn(&installCompFlags.step);
    // lsp.dependOn(&installCppProps.step);
}

pub fn addPlatformioIniStep(
    b: *std.Build,
    helpers: *std.Build.Module,
    chicot: *std.Build.Dependency,
    pioDiffMode: bool,
    allocator: std.mem.Allocator,
) !void {
    const pioIniModule = b.addModule("pioIni", .{
        .root_source_file = chicot.path("src/helpers/generators/platformIoIni.zig"),
        .optimize = .Debug,
        .target = b.graph.host,
    });
    pioIniModule.addImport("helpers", helpers);
    const options = b.addOptions();
    options.addOption([]const u8, "zonFile", "build.zig.zon");
    pioIniModule.addOptions("config", options);
    pioIniModule.addAnonymousImport("zon", .{
        .root_source_file = b.path("build.zig.zon"),
    });

    const pioIniProgram = b.addExecutable(.{
        .name = "pioini",
        .root_module = pioIniModule,
    });

    const runPioIni = b.addRunArtifact(pioIniProgram);

    const output = runPioIni.addOutputFileArg("platformio.ini");
    const outputCheckPioPy = runPioIni.addOutputFileArg("checkpio.py");
    if (pioDiffMode) {
        const pioIniContents = try getFileContents(
            std.fs.cwd(),
            "platformio.ini",
            allocator,
            40000,
        );
        defer allocator.free(pioIniContents);
        runPioIni.addArg(pioIniContents);

        const checkpioContents = try getFileContents(
            std.fs.cwd(),
            "checkpio.py",
            allocator,
            40000,
        );
        defer allocator.free(checkpioContents);
        runPioIni.addArg(checkpioContents);
    } else {
        runPioIni.addArg("");
        runPioIni.addArg("");
    }

    const installPioIni = b.addInstallFile(output, "platformio.ini");
    const installPioCheckPy = b.addInstallFile(outputCheckPioPy, "checkpio.py");

    // b.getInstallStep().dependOn(&installPioIni.step);

    const pioIni = b.step("pio", "generate the platformio.ini file");
    pioIni.dependOn(&installPioIni.step);
    pioIni.dependOn(&installPioCheckPy.step);
}
