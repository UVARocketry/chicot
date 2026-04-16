# Chicot

This is the repository for the new build system for UVA Rocketry. It's "just a build.zig script"

## But why?

It's a very reasonable question why a repo with 3k+ lines of zig just to build some c++ even needs to exist. So, why?

There are numerous reasons, most of them boil down to the fact that platformio's build system is... pretty bad:

- building for desktop targets or python modules (like we need for RocketPy testing and generic testing) is (afaik) impossible on platformio
- due to the above reason, easily sharing build flags across platformio and whatever other build system we use is basically impossible
- allowing transitive dependencies on our repos is needlessly difficult because it requires us to maintain a separate library.json file (which adds a third source of truth to builds?)
- integrating zig code into our code is very sus right now, even though it would be *very* beneficial in some places
- LSP information generation is NOT possible to do not manually right now (at least with a fancy build.zig script, cmake could probably be done easily though, but I don't want to EVER touch cmake)

## Solution

The solution is this monstrosity of a build script. It autogenerates:

1. platformio.ini
0. library.json (for dependencies to be usable from platformio)
0. LSP Information

Since this script is just a build.zig script, users can modify the returned modules to add all their own special information, making this super powerful. Also, since it's a "just" build.zig script it will ALSO build zig code, which enables using zig's testing system, which is LEAGUES better than C++ testing

## How to use

With Chicot, ALL information comes from the build.zig.zon file. This makes it so that there is ONLY one source of truth about the build

### Commands

There are a few commands to use different aspects of chicot:

#### Lsp Information Generation

Fortunately, getting up and running writing code inside your editor is super easy. First, you must build everything with `zig build` (or `zig build -Dmode=...` if you want to specify a specific mode)

Then, all you have to do is `zig build lsp -p .` (or `zig build lsp -p . -Dmode=...`)

This command will always modify the `compile_flags.txt` in the same directory as the `build.zig.zon` file

#### Lsp usage in vscode

Unfortunately, chicot does ***not*** currently support lsp information generation for Microsoft's C/C++ Extension. If you want autocomplete and all those nice features inside vscode, install the [clangd](https://marketplace.visualstudio.com/items?itemName=llvm-vs-code-extensions.vscode-clangd) extension. Vscode *should* prompt you to disable intellisense after the installation of clangd, which you should accept.

If you have updated the lsp information (with `zig build lsp -p .`) but clangd is still showing errors then save the file and everything should start working again.

#### Platformio.ini generation

If a project is setup to use platformio for the embedded build system, then you will need to run `zig build pio -p .` to autogenerate the `platformio.ini` and accompanying `checkpio.py` build files. If the platformio.ini file is out of sync with Chicot's current build info, then platformio will prompt you to rerun `zig build pio -p .` when you next run `pio run ...`

#### Platformio Library Usage

If you want to package up your current project as a platformio library, then run `zig build libraryjson` to generate the `library.json` file that platformio needs. Note that this ***will NOT*** package up zig exported symbols, so use this with care

## Build System Reference

### build.zig

The `build.zig` file is the entry point for the Zig build system. When using Chicot, your `build.zig` should be minimal and delegate all work to the Chicot build function.

#### Minimal build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) !void {
    const chicotDep = b.lazyDependency("chicot", .{}) orelse return;
    const chicot = @import("chicot");

    _ = try chicot.chicotBuild(b, chicotDep, @import("build.zig.zon"), .{});
}
```

#### build.zig with External Dependencies

If you need to add external Zig dependencies (e.g. dependencies that aren't also built with chicot), you can extend the build.zig:

```zig
const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) !void {
    const chicotDep = b.lazyDependency("chicot", .{}) orelse return;
    const chicot = @import("chicot");

    const modules = try chicot.chicotBuild(b, chicotDep, @import("build.zig.zon"), .{});

    // Add external Zig dependencies to the build
    const dep = b.dependency("websocket", .{});
    // make it publicly available to the main src/root.zig module
    modules.libzigMod.addImport("websocket", dep.module("websocket"));
    if (modules.exeMod) |exe| {
        // make it publicly available to the executable module as well 
        // if we are building on desktop
        exe.addImport("websocket", dep.module("websocket"));
    }
}
```

#### build.zig with Custom Include Paths

You can add custom include paths to the Zig module after the Chicot build:

```zig
const std = @import("std");

pub fn build(b: *std.Build) !void {
    const chicotDep = b.lazyDependency("chicot", .{}) orelse return;
    const chicot = @import("chicot");

    const mods = try chicot.chicotBuild(b, chicotDep, @import("build.zig.zon"), .{});
    mods.libzigMod.addIncludePath(b.path("./.pio/libdeps/teensy41/llcc68_driver/src/"));
}
```

#### Function: `chicotBuild`

```zig
pub fn build(
    b: *std.Build,
    chicot: *std.Build.Dependency,
    zon: anytype,
    options: BuildOptions,
) !Modules
```

**Parameters:**

- `b`: The Zig build context
- `chicot`: The Chicot dependency (obtained via `b.lazyDependency("chicot", .{})`)
- `zon`: The parsed build.zig.zon file (passed as `@import("build.zig.zon")`)
- `options`: Build options (currently unused, pass `.{}`)

**Returns:** `Modules` struct containing all the built modules and libraries:

- `libzig`: The static library containing Zig code
- `libzigMod`: The Zig module (can be used to add imports)
- `libcpp`: The static library containing C++ code
- `libcppForDeps`: Library for linking C++ dependencies
- `depLibcpps`: Array of dependency C++ libraries
- `depLibzigs`: Array of dependency Zig libraries
- `rootTests`: Test executable (if applicable)
- `cppMod`: The C++ module
- `zigobject`: Object file for Zig code
- `compatHeadersDir`: Path to compatibility headers
- `depHeadersDir`: Path to dependency headers
- `platformioClangdCompatHeaders`: PlatformIO clangd compatibility headers
- `lib`: Combined library
- `headerLib`: Library containing headers
- `depHeaderLib`: Library containing dependency headers
- `pythonMod`: Python module (if building Python bindings)
- `python`: Python library (if building Python bindings)
- `exeMod`: Desktop executable module (if building exe)
- `exe`: Desktop executable (if building exe)
- `check`: Check step for compilation verification

### build.zig.zon

The `build.zig.zon` file is the single source of truth for your project configuration. It defines dependencies, build modes, compiler flags, and output targets.

#### Structure

```zig
.{
    // Standard Zig package fields
    .name = .your_project_name,
    .version = "0.0.1",
    .fingerprint = 0x...,  // Unique package fingerprint
    .minimum_zig_version = "0.15.1",
    
    // Dependencies
    .dependencies = .{
        .chicot = .{
            .url = "git+https://github.com/UvaRocketry/chicot#commit_hash",
            .hash = "chicot-0.0.1-...",
        },
        .other_dep = .{
            .path = "../other_dep",
        },
    },
    
    // Files to include in the package
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "desktop",  // Optional: for desktop executables
    },
    
    // Chicot-specific configuration
    .chicotversion = "0.0.0",
    
    .builddefaults = .{
        .mode = "desktop",
        .targets = .{
            .teensy = .{
                .arch_os_abi = "thumb-freestanding-eabihf",
                .cpu_features = "cortex_m7+fp_armv8d16",
            },
        },
    },
    
    .buildmodes = .{
        // Define your build modes here
    },
}
```

#### Top-Level Fields

##### `name` (required)
The package name as an enum literal (e.g., `.myproject`).

##### `version` (required)
Semantic version string (e.g., `"0.0.1"`).

##### `fingerprint` (required)
Unique package fingerprint for Zig's package manager.

##### `minimum_zig_version` (required)
Minimum required Zig version (e.g., `"0.15.1"`).

##### `dependencies` (required)
Map of dependencies. Must include at least `chicot`.

Dependency format:
- **Git dependency**: `{ .url = "git+https://github.com/...#commit_hash", .hash = "..." }`
- **Local path dependency**: `{ .path = "../relative/path" }`

##### `paths` (required)
Array of paths to include in the package:
- `"build.zig"` - The build script
- `"build.zig.zon"` - This configuration file
- `"src"` - Source code directory
- `"desktop"` - Desktop application code (optional, for building executables)
- `"python"` - Python bindings (optional, for building Python modules)

##### `chicotversion` (required)
Chicot build system version (currently `"0.0.0"`).

##### `builddefaults` (optional)
Default build configuration:

```zig
.builddefaults = .{
    // Default build mode if not specified
    .mode = "desktop",
    
    // Target definitions
    .targets = .{
        .teensy = .{
            .arch_os_abi = "thumb-freestanding-eabihf",
            .cpu_features = "cortex_m7+fp_armv8d16",
        },
    },
}
```

##### `buildmodes` (required)
Map of build mode configurations. Each mode defines how the project should be built.

**Required build modes:**
- `desktop` - For building desktop executables and tests
- `teensy41` - For building Teensy 4.1 embedded targets

#### Build Mode Structure

Each build mode is a struct with the following fields:

##### `description` (required)
Human-readable description of the build mode.

##### `inherit` (optional)
Name of another build mode to inherit settings from. Use `null` for root modes.

```zig
.inherit = "shared",  // Inherit from "shared" mode
```

##### `target` (optional)
Target identifier (references a key from `builddefaults.targets`).

```zig
.target = "teensy",
```

##### `optimize` (optional)
Optimization mode. One of:
- `.Debug` - Debug builds (default for desktop)
- `.ReleaseSafe` - Safe release builds
- `.ReleaseFast` - Fast release builds
- `.ReleaseSmall` - Small binary size

##### `outputTypes` (optional)
Array of output types to generate:

- `.libzig` - Static library with Zig code
- `.liball` - Static library with all code (Zig + C++)
- `.pythonmodule` - Python extension module
- `.exe` - Desktop executable
- `.platformioini` - PlatformIO configuration

```zig
.outputTypes = .{
    .libzig,
    .exe,
},
```

##### `dependencies` (optional)
Array of dependency specifications:

```zig
.dependencies = .{
    .{ .dependencyName = "stl" },
    .{ .dependencyName = "vec", .importName = "vector" },  // With custom import name
},
```

Fields:
- `dependencyName` (required): Name of the dependency as declared in the dependencies section
- `importName` (optional): Custom name for importing the dependency in Zig (defaults to dependencyName)

##### `cpp` (optional)
C++ compiler configuration:

```zig
.cpp = .{
    // Compiler flags (e.g., -std=c++23)
    .otherFlags = .{
        "-std=c++23",
        "-Wall",
        "-Wextra",
    },
    
    // Include directories (will be prefixed with -I)
    .include = .{
        "include",
        "third_party",
    },
    
    // Link library names (will be prefixed with -l)
    .linkPath = .{
        "m",  // math library
    },
    
    // Preprocessor definitions
    .define = .{
        .FLOAT = "float",
        .DEBUG = "1",
        .RELEASE = null,  // Defined with no value
    },
    
    // Flags that must be present (for validation)
    .requiredFlags = .{
        "-DFLOAT=",
    },
    
    // Flags that can be overridden by parent projects
    .overrideableFlags = .{
        "-O",
    },
}
```

##### `platformio` (optional)
PlatformIO configuration for embedded builds:

```zig
.platformio = .{
    .platform = "teensy",
    .board = "teensy41",
    .framework = "arduino",
    .build_type = "release",
    
    // Additional PlatformIO library dependencies
    .lib_deps = .{
        "Wire",
        "SPI",
        "sandeepmistry/LoRa@^0.8.0",
    },
    
    // Extra Python scripts to run during build
    .extra_scripts = .{
        "pre:idk.py",
    },
}
```

##### `installHeaders` (optional)
Array of additional header directories to install:

```zig
.installHeaders = .{
    .{ .fromDir = "include", .toDir = "" },
    .{ .fromDir = "third_party/headers", .toDir = "third_party" },
},
```

##### `headergen` (optional)
Configuration for C header generation from Zig code:

```zig
.headergen = .{
    .{ .ignoreType = "InternalStruct" },  // Exclude types from header
    .{ .addInclude = "extra_header.h" },   // Add additional includes
    .{ .ignoreDecl = "internal_func" },    // Exclude declarations
},
```

### Build Steps

The Chicot build system provides several build steps that can be invoked with `zig build <step>`:

#### `install` (default)
Builds and installs all configured outputs.

**Options:**
- `-Dmode=<mode>` - Build in specific mode (e.g., `-Dmode=teensy41`)
- `-Dtarget=<target>` - Override target triple
- `-Doptimize=<mode>` - Override optimization (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall)

#### `test`
Runs Zig tests from `src/root.zig`.

#### `run`
Runs the desktop executable (if `exe` output type is configured).

Passes additional arguments to the executable:
```bash
zig build run -- arg1 arg2
```

#### `check`
Verifies that everything compiles without errors (does not produce output).

#### `lsp`
Generates LSP configuration files for clangd.

**Options:**
- `-p <path>` - Installation prefix path (usually `-p .`)
- `-Dmode=<mode>` - Build mode for LSP configuration

#### `pio`
Generates `platformio.ini` and supporting files for PlatformIO builds.

**Options:**
- `-p <path>` - Installation prefix path
- `-Dmode=<mode>` - Build mode (usually `teensy41`)
- `-Ddiff=<bool>` - Whether to diff with existing platformio.ini

#### `libraryjson`
Generates `library.json` for publishing as a PlatformIO library.

#### `header`
Generates a C/C++ header file that exports all public symbols from `src/root.zig`.

#### `py`
Installs the Python module to the canonical location (`python/<name>.so` or `python/<name>.pyd`).

**Options:**
- `-DforceBuildPy=<bool>` - Force building Python modules even when cross-compiling

### Directory Structure

Chicot expects the following directory structure:

```
project/
├── build.zig              # Build script
├── build.zig.zon          # Project configuration
├── src/                   # Source code
│   ├── root.zig          # Main Zig module (optional)
│   ├── *.cpp             # C++ source files (optional)
│   └── *.h               # C++ headers (optional)
├── desktop/              # Desktop application code
│   └── main.zig          # Desktop entry point (optional)
├── python/               # Python bindings
│   └── python.zig        # Python module entry (optional)
└── ...
```

### Inheritance

Build modes support inheritance to reduce duplication. Use the `inherit` field to specify a parent mode:

```zig
.buildmodes = .{
    .shared = .{
        .description = "Common settings",
        .cpp = .{ .otherFlags = .{"-std=c++23"} },
        .inherit = null,
    },
    .desktop = .{
        .description = "Desktop build",
        .inherit = "shared",  // Inherits cpp flags from "shared"
        .cpp = .{
            .otherFlags = .{"-Wall"},  // Merged with inherited flags
        },
    },
}
```

Inheritable fields:
- `cpp` - Merged (flags are appended)
- `target` - Overridden if specified
- `platformio` - Merged
- `dependencies` - Merged (dependencies are combined)
- `outputTypes` - Overridden if specified
- `installHeaders` - Merged
- `headergen` - Merged

### Environment Variables

Chicot recognizes the following environment variables:

- `HOME` / `USERPROFILE` (Windows) - Used to find PlatformIO installation
- Standard Zig environment variables for target selection

### Cross-Compilation

To cross-compile for different targets:

```bash
# Build for Teensy 4.1
zig build -Dmode=teensy41

# Build for desktop with specific target
zig build -Dtarget=aarch64-linux-gnu

# Build for Windows from Linux/macOS
zig build -Dtarget=x86_64-windows-gnu
```

### Python Module Building

To build Python extension modules:

1. Create `python/python.zig` with your module code
2. Add `pythonmodule` to `outputTypes` in your build mode
3. Build: `zig build -Dmode=desktop`
4. Install: `zig build py`

Note: Python modules are automatically skipped when cross-compiling unless `-DforceBuildPy=true` is set.

### PlatformIO Integration

Chicot generates all necessary files for PlatformIO:

1. Generate configuration: `zig build pio -p . -Dmode=teensy41`
2. Build with PlatformIO: `pio run`

The build system will:
- Generate `platformio.ini` with all settings
- Generate `checkpio.py` to validate configuration
- Build `libzig` library for linking
- Set up all include paths and dependencies

### Examples

#### Basic Desktop Project

```zig
// build.zig.zon
.{
    .name = .myproject,
    .version = "0.0.1",
    .fingerprint = 0x1234567890abcdef,
    .minimum_zig_version = "0.15.1",
    .dependencies = .{
        .chicot = .{
            .url = "git+https://github.com/UvaRocketry/chicot#a832f0a",
            .hash = "chicot-0.0.1-...",
        },
    },
    .paths = .{"build.zig", "build.zig.zon", "src"},
    .chicotversion = "0.0.0",
    .buildmodes = .{
        .desktop = .{
            .description = "Desktop build",
            .outputTypes = .{.libzig},
            .cpp = .{ .otherFlags = .{"-std=c++23"} },
        },
        .teensy41 = .{
            .description = "Teensy build",
            .outputTypes = .{.libzig},
            .target = "teensy",
            .platformio = .{
                .platform = "teensy",
                .board = "teensy41",
                .framework = "arduino",
            },
        },
    },
}
```

#### Project with Python Bindings

```zig
// build.zig.zon
.{
    // ... standard fields ...
    .paths = .{"build.zig", "build.zig.zon", "src", "python"},
    .buildmodes = .{
        .desktop = .{
            .description = "Desktop with Python",
            .outputTypes = .{.libzig, .pythonmodule},
            .dependencies = .{
                .{ .dependencyName = "stl" },
            },
        },
    },
}
```

#### Project with Desktop Executable

```zig
// build.zig.zon
.{
    // ... standard fields ...
    .paths = .{"build.zig", "build.zig.zon", "src", "desktop"},
    .buildmodes = .{
        .desktop = .{
            .description = "Desktop app",
            .outputTypes = .{.libzig, .exe},
            .dependencies = .{
                .{ .dependencyName = "stl" },
                .{ .dependencyName = "debugger" },
            },
        },
    },
}
```

#### Complex Project with Inheritance

```zig
// build.zig.zon
.{
    // ... standard fields ...
    .buildmodes = .{
        .shared = .{
            .description = "Common settings",
            .cpp = .{
                .otherFlags = .{"-std=c++23"},
                .define = .{.FLOAT = "float"},
            },
            .dependencies = .{
                .{ .dependencyName = "stl" },
                .{ .dependencyName = "vec" },
            },
            .inherit = null,
            .outputTypes = .{},
        },
        .desktopshared = .{
            .description = "Desktop shared settings",
            .inherit = "shared",
            .cpp = .{
                .otherFlags = .{"-Wall", "-Wextra"},
                .define = .{.DESKTOP = ""},
            },
        },
        .desktop = .{
            .description = "Desktop executable",
            .inherit = "desktopshared",
            .outputTypes = .{.libzig, .exe, .pythonmodule},
            .dependencies = .{
                .{ .dependencyName = "debugger" },
            },
        },
        .teensy41 = .{
            .description = "Teensy embedded",
            .inherit = "shared",
            .outputTypes = .{.libzig},
            .target = "teensy",
            .platformio = .{
                .platform = "teensy",
                .board = "teensy41",
                .framework = "arduino",
            },
        },
    },
}
```
