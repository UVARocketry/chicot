const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("helpers");
const ZonType = helpers.buildInfo.ZonType;
const zon = @import("zon");
const zonParse = helpers.parseZon;
const inherit = helpers.inherit;

pub fn main() !void {
    // var cwdBuf: [500]u8 = undefined;

    const allocator = std.heap.smp_allocator;
    var zonParseArena: std.heap.ArenaAllocator = .init(allocator);
    const arena = zonParseArena.allocator();

    var val = zonParse.parseZonStruct(
        arena,
        ZonType,
        zon.buildmodes,
        ".buildmodes",
    );

    try inherit.resolveInheritance(arena, &val);

    var argIterator = try std.process.argsWithAllocator(allocator);
    if (argIterator.next()) |_| {} else {
        return error.NoArgs;
    }

    const pioPath = argIterator.next() orelse return error.NoArgs;

    const proc = try runProcess(.{
        .allocator = allocator,
        .argv = &.{ pioPath, "system", "info" },
    });

    var buf: [512]u8 = undefined;
    var soWriter = std.fs.File.stdout().writer(&buf);
    const stdout = &soWriter.interface;

    // we can leak stdout and stderr here bc it will be cleaned up once prog exits
    // which will be very shortly

    var splitIter = std.mem.splitScalar(u8, proc.stdout, '\n');

    while (splitIter.next()) |v| {
        if (v.len == 0) {
            continue;
        }
        const str =
            // windows uses \r\n line endings, so detect that and delete it
            if (comptime builtin.os.tag == .windows and v[v.len - 1] == '\r')
                v[0 .. v.len - 1]
            else
                v;

        const searchString = "PlatformIO Core Directory";
        if (std.mem.startsWith(u8, str, searchString)) {
            var rest = str[searchString.len..];

            while (rest.len > 0 and isAsciiSpace(rest[0])) {
                rest = rest[1..];
            }

            try stdout.writeAll(rest);
        }
    }
    try stdout.flush();
}

fn isAsciiSpace(char: u8) bool {
    return char <= ' ' and char > 0;
}

const runProcess = if (builtin.zig_version.minor >= 12) std.process.Child.run else std.process.Child.exec;
