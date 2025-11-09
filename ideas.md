# ideas

modes is STUPID!!! it forces all dependencies to have the same mode (ew) defined while also not *really* adding anything helpful. what we could just do is prevent multiple environments (which makes sense for a distributed system bc we can just have separate repos).

we could just have a `targetType` field which users can call to set the default target. 

```sh
zig build -DtargetType=teensy41

# then dependencies just get zig build -Dtarget=...
```

```zig
const targetType = b.option([]const u8, "targetType", "idk");
```

and we can have an `outputType` field which sets the default output

```sh
zig build -DoutputType=libzig
```

```zig
const outputType = b.option([]BuildMode.OutputType, "outputTypes", "idk");
```

whatif buildmodes just had two values: `desktop` and `teensy41`? like keep it opinionated ykyk. OR `desktopWindows`, `desktopLinux`, and `desktopMac`. OR `desktop` PLUS the previous 3 as modes that we inherit from

and whatif instead of needing to *include* dependencies, we *exclude* the ones that we dont want. so like installing a dependeny defaults to including it. BUT this would make it so that you cant rename dependencies (ew) so lowkey maybe nvm

would it be possible to set required flags? like libeigen could say that it NEEDS `-DEIGEN_DONT_VECTORIZE` on windows ykyk

soooo like all dependencies just inherit flags?

```zig
const flags = b.option([][]const u8, "flags", "idk");
```

no. they can specify their own flags (eg for actual compileable code), but they can also say required flags (eg for header libs like eigen)

okok, we ARE NOT passing flags on the cmd line bc then i need to parse them (EW)

wellllll, if we are passing flags downward, then we NEED to be able to parse them. whatif we made parsing like super simple? like replace ' ' with %s or something

well actually, we only need to say required flags (eg -std=c++23) and defines (-DEIGEN_DONT_VECTORIZE), we dont have to go crazy like actually parsing values and stuff, we just have a command line arg like `flagsSet`

i remember something about flags to be passed all the way down the tree (eg `-DDT_MS`) and those that are just parent to child flags (like `-DEIGEN_DONT_VECTORIZE`)

```zig
const flagsFromParent = b.option([][]const u8, "parentFlags", "idk");
const flagsFromRoot   = b.option([][]const u8,   "rootFlags", "idk");
```

once it's in a string array form it's very ez to parse: `-I`, `-D`, `-l`, `-L`, etc

some build flags need to be overrideable by the parent (eg `-DFLOAT`) MUST ONLY BE SET IN ONE PLACE!!! (otherwise there will be very *very* odd/confusing/annoying abi compat issues). How do we want to specify that some flags (just macros?) should be overriden? we could default to ALL macros being overriden and nothing else? we could add some field like `overrideableFlags` or something?

## OKOKOK

sooooo... we need to decouple the mode passing. really, mode passing is only for a user facing thing? like really the only reason for modes is js to group c++ flags. dependencies can have flags overriden by setting `.cpp.overrideableFlags`. like with flag passing, we dont *really* need modes ykyk. flag resolution for building only needs to happen on desktop lowkey. so like ig the way it works is users can set `-Dmode=`. sooo myabe maybe idrk but basically `desktop` mode is what we get the flags for building libs from and then the passed flags overrides/modifies the flags for the lib. 

yehh flag resolution doesnt even matter on platformio builds bc we dont care about flags on libzig. this might change in the future for conditional compilation but c'est la vie
