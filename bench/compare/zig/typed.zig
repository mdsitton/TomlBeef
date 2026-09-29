// zig-toml typed serialization of typed.toml (../typed.sh): zig-toml-typed <read|write> <file> <min-samples>
// zig-toml maps a parsed table into a struct by comptime reflection (Parser(TypedRoot)). read times
// text -> new TypedRoot (MB/s of input, parse + free). write is unsupported: toml.serialize does not
// compile for a slice of structs (an array of tables; zig-toml 8685923, serialize/root.zig:216).
// Built with -O ReleaseFast.
const std = @import("std");
const toml = @import("toml");

const TypedLimits = struct { max_connections: i32, timeout_ms: i32 };

const TypedServer = struct {
    name: []const u8,
    host: []const u8,
    port: i32,
    enabled: bool,
    weight: f64,
    tags: []const []const u8,
    limits: TypedLimits,
};

const TypedRoot = struct {
    title: []const u8,
    version: i32,
    debug: bool,
    servers: []const TypedServer,
};

const Measurement = struct { median_ns: f64, samples: usize, converged: bool };

/// The shared rule (see bench.zig `measure` and ../run.sh).
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

/// "servers ports max_connections tags enabled", the same line every typed harness prints
fn printCheck(prefix: []const u8, root: *const TypedRoot) void {
    var ports: i64 = 0;
    var connections: i64 = 0;
    var tags: usize = 0;
    var enabled: usize = 0;
    for (root.servers) |s| {
        ports += s.port;
        connections += s.limits.max_connections;
        tags += s.tags.len;
        if (s.enabled) enabled += 1;
    }
    std.debug.print("{s}check: {d} {d} {d} {d} {d}\n", .{ prefix, root.servers.len, ports, connections, tags, enabled });
}

const ReadContext = struct { parser: *toml.Parser(TypedRoot), text: []const u8 };

fn readOnce(ctx: *ReadContext) void {
    const result = ctx.parser.parseString(ctx.text) catch unreachable;
    result.deinit();
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) {
        std.debug.print("usage: zig-toml-typed <read|write> <file> <min-samples>\n", .{});
        std.process.exit(2);
    }
    const io = init.io;
    const gpa = init.gpa;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, args[2], gpa, .unlimited);
    defer gpa.free(text);
    const min_samples = try std.fmt.parseInt(usize, args[3], 10);

    var parser = toml.Parser(TypedRoot).init(gpa);
    defer parser.deinit();
    const model = parser.parseString(text) catch |err| {
        std.debug.print("read error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer model.deinit();
    printCheck("", &model.value);

    if (!std.mem.eql(u8, args[1], "read")) {
        std.debug.print("unsupported: zig-toml cannot serialize an array of tables\n", .{});
        std.process.exit(3);
    }
    var ctx: ReadContext = .{ .parser = &parser, .text = text };
    const m = try measure(io, gpa, min_samples, &ctx, readOnce);
    const ms = m.median_ns / 1e6;
    const mbps = @as(f64, @floatFromInt(text.len)) / 1048576.0 / (ms / 1000.0);
    std.debug.print("{d:.3} ms/op {d:.1} MB/s (n={d}, {s})\n", .{ ms, mbps, m.samples, if (m.converged) "converged" else "capped" });
}
