// zig-toml benchmark: bench <file> <iterations>
// Reads the file once, parses it once to warm up, then times up to <iterations> parses (3 s budget)
// into toml.Table, zig-toml's schema-less table (parse + free). Built with -O ReleaseFast.
const std = @import("std");
const toml = @import("toml");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: bench <file> <iterations>\n", .{});
        std.process.exit(2);
    }
    const io = init.io;
    const gpa = init.gpa;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .unlimited);
    defer gpa.free(text);
    const iterations = try std.fmt.parseInt(usize, args[2], 10);

    var parser = toml.Parser(toml.Table).init(gpa);
    defer parser.deinit();
    {
        const warm = parser.parseString(text) catch |err| {
            std.debug.print("parse error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        warm.deinit();
    }

    // Stop after <iterations> parses or 3 s, whichever comes first (at least one)
    const start = std.Io.Timestamp.now(io, .awake);
    var done: usize = 0;
    while (done < iterations and (done == 0 or start.untilNow(io, .awake).nanoseconds < 3 * std.time.ns_per_s)) : (done += 1) {
        const result = try parser.parseString(text);
        result.deinit();
    }
    const ns: f64 = @floatFromInt(start.untilNow(io, .awake).nanoseconds);
    const ms = ns / 1e6 / @as(f64, @floatFromInt(done));
    const mbps = @as(f64, @floatFromInt(text.len)) / 1048576.0 / (ms / 1000.0);
    std.debug.print("{d:.3} ms/op {d:.1} MB/s\n", .{ ms, mbps });
}
