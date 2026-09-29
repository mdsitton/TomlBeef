// zig-toml benchmark: bench <file> <min-samples> [lookups]
// Parse mode times single parses into toml.Table, zig-toml's schema-less table (parse + free), under
// the shared rule (see `measure` and run.sh). With a lookups file, parses once and times key lookups
// instead (lookup.sh). Built with -O ReleaseFast.
const std = @import("std");
const toml = @import("toml");

const Measurement = struct { median_ns: f64, samples: usize, converged: bool };

/// Warm up for at least 1 s (at least one run), then time single runs until at least `min_samples`
/// were taken and at least 60% lie within ±10% of their median, or 10 s / 1000 samples have passed.
fn measure(io: std.Io, gpa: std.mem.Allocator, min_samples: usize, context: anytype, comptime op: fn (@TypeOf(context)) void) !Measurement {
    const warm = std.Io.Timestamp.now(io, .awake);
    while (true) {
        op(context);
        if (warm.untilNow(io, .awake).nanoseconds >= std.time.ns_per_s) break;
    }
    var samples: std.ArrayList(f64) = .empty;
    defer samples.deinit(gpa);
    var sorted: std.ArrayList(f64) = .empty;
    defer sorted.deinit(gpa);
    const start = std.Io.Timestamp.now(io, .awake);
    while (true) {
        const t0 = std.Io.Timestamp.now(io, .awake);
        op(context);
        try samples.append(gpa, @floatFromInt(t0.untilNow(io, .awake).nanoseconds));
        sorted.clearRetainingCapacity();
        try sorted.appendSlice(gpa, samples.items);
        std.mem.sort(f64, sorted.items, {}, std.sort.asc(f64));
        const n = sorted.items.len;
        const median = if (n % 2 == 1) sorted.items[n / 2] else (sorted.items[n / 2 - 1] + sorted.items[n / 2]) / 2;
        if (n >= min_samples) {
            var within: usize = 0;
            for (samples.items) |s| {
                if (s >= median * 0.9 and s <= median * 1.1) within += 1;
            }
            if (@as(f64, @floatFromInt(within)) >= 0.6 * @as(f64, @floatFromInt(n)))
                return .{ .median_ns = median, .samples = n, .converged = true };
        }
        if (n >= 1000 or start.untilNow(io, .awake).nanoseconds >= 10 * std.time.ns_per_s)
            return .{ .median_ns = median, .samples = n, .converged = false };
    }
}

fn status(m: Measurement) []const u8 {
    return if (m.converged) "converged" else "capped";
}

const ParseContext = struct { parser: *toml.Parser(toml.Table), text: []const u8 };

fn parseOnce(ctx: *ParseContext) void {
    const result = ctx.parser.parseString(ctx.text) catch unreachable;
    result.deinit();
}

const LookupContext = struct {
    root: *const toml.Table,
    tables: []const []const u8,
    keys: []const []const u8,
    sum: i64 = 0,
    missing: usize = 0,
};

fn lookupPass(ctx: *LookupContext) void {
    ctx.sum = 0;
    ctx.missing = 0;
    for (ctx.tables, ctx.keys) |t, k| {
        const found: ?i64 = blk: {
            const table_value = ctx.root.get(t) orelse break :blk null;
            if (table_value != .table) break :blk null;
            const value = table_value.table.get(k) orelse break :blk null;
            if (value != .integer) break :blk null;
            break :blk value.integer;
        };
        std.mem.doNotOptimizeAway(found);
        if (found) |v| ctx.sum += v else ctx.missing += 1;
    }
}

fn lookupBench(io: std.Io, gpa: std.mem.Allocator, root: *const toml.Table, path: []const u8, min_samples: usize) !void {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(text);
    var tables: std.ArrayList([]const u8) = .empty;
    var keys: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ').?;
        try tables.append(gpa, line[0..space]);
        try keys.append(gpa, line[space + 1 ..]);
    }
    var ctx: LookupContext = .{ .root = root, .tables = tables.items, .keys = keys.items };
    const m = try measure(io, gpa, min_samples, &ctx, lookupPass);
    std.debug.print("{d:.1} ns/lookup, {d} lookups, sum {d}, missing {d} (n={d}, {s})\n", .{
        m.median_ns / @as(f64, @floatFromInt(tables.items.len)), tables.items.len, ctx.sum, ctx.missing, m.samples, status(m),
    });
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: bench <file> <min-samples> [lookups]\n", .{});
        std.process.exit(2);
    }
    const io = init.io;
    const gpa = init.gpa;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .unlimited);
    defer gpa.free(text);
    const min_samples = try std.fmt.parseInt(usize, args[2], 10);

    var parser = toml.Parser(toml.Table).init(gpa);
    defer parser.deinit();
    const first = parser.parseString(text) catch |err| {
        std.debug.print("parse error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (args.len >= 4) {
        try lookupBench(io, gpa, &first.value, args[3], min_samples);
        return;
    }
    first.deinit();

    var ctx: ParseContext = .{ .parser = &parser, .text = text };
    const m = try measure(io, gpa, min_samples, &ctx, parseOnce);
    const ms = m.median_ns / 1e6;
    const mbps = @as(f64, @floatFromInt(text.len)) / 1048576.0 / (ms / 1000.0);
    std.debug.print("{d:.3} ms/op {d:.1} MB/s (n={d}, {s})\n", .{ ms, mbps, m.samples, status(m) });
}
