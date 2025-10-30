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

0. platformio.ini
0. library.json (for dependencies to be usable from platformio)
0. LSP Information

Since this script is just a build.zig script, users can modify the returned modules to add all their own special information, making this super powerful. Also, since it's a "just" build.zig script it will ALSO build zig code, which enables using zig's testing system, which is LEAGUES better than C++ testing

## How to use

With Chicot, ALL information comes from the build.zig.zon file. This makes it so that there is ONLY one source of truth about the build
