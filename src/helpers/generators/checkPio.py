import subprocess

p2 = subprocess.Popen(
    ["zig", "build", "pio", "-Ddiff"], shell=False, stderr=subprocess.PIPE, text=True
)
p2.wait()

if p2.returncode != 0:
    print(
        "It appears some component of your platformio.ini script system is out of date! Please update it by running the following command in your terminal:\n    zig build pio -p ."
    )
    raise Exception("OutOfDatePlatformioIni")

env = DefaultEnvironment()

mode = env["PIOENV"]

# cant use ReleaseSmall bc it messes with stack trace info
p1 = subprocess.Popen(
    ["zig", "build", "-Doptimize=ReleaseFast", "-Dmode=" + mode],
    shell=False,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
p1.wait()

if p1.returncode != 0:
    print(
        "Zig build failed! Please fix this before continuing the build\nCommand ran:   zig build -Doptimize=ReleaseSmall -Dmode="
        + mode
    )
    raise Exception("FailedZigBuild")
