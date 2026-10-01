//! Runnable demonstration of the htscodecs facade.
//!
//! `zig build smoke` runs this and prints a fixed report: the same inputs,
//! the same codecs, the same numbers, every time.  Nothing here depends on
//! timing, addresses, environment or the file system.  A mismatch against
//! an upstream fixture is a hard error, not a printed warning, so the smoke
//! step fails loudly if the library stops being interoperable.

const std = @import("std");
const htscodecs = @import("htscodecs");
const fx = @import("fixtures");

/// One row of the compression table.  `method` is the order byte, which
/// means different things for rANS 4x16 (0x04 is X32) and for the
/// arithmetic coder (0x04 is the bzip2 external method, compiled out by
/// default), so the applicability is recorded per row.
const Method = struct {
    codec: []const u8,
    label: []const u8,
    method: c_int,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    defer file_writer.flush() catch {};
    const out = &file_writer.interface;

    try out.print("htscodecs {s} (packed version {d})\n\n", .{
        htscodecs.versionText(),
        htscodecs.version(),
    });

    try reportCompression(out, gpa);
    try reportInteroperability(out, gpa);
    try reportOwnership(out, gpa);
}

/// Column 1 of the q4 corpus, which is the block every q4 fixture is built
/// from: the concatenated quality characters with the line terminators
/// removed, exactly as upstream's `cut -f 1 | tr -d '\012'` produces.
fn q4Payload(gpa: std.mem.Allocator) ![]u8 {
    const scratch = try gpa.alloc(u8, fx.source.q4.len);
    defer gpa.free(scratch);
    return gpa.dupe(u8, fx.qualityPayload(fx.source.q4, scratch));
}

fn reportRow(out: *std.Io.Writer, row: Method, input: usize, output: usize) !void {
    const permille = output * 1000 / input;
    try out.print("  {s: <10}{s: <10}{d: >4}{d: >12}{d: >10}{d: >9}\n", .{
        row.codec,
        row.label,
        row.method,
        input,
        output,
        permille,
    });
}

fn reportCompression(out: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    const payload = try q4Payload(gpa);
    defer gpa.free(payload);

    try out.print("compression of the upstream q4 corpus ({d} bytes)\n", .{payload.len});
    try out.print("  {s: <10}{s: <10}{s: >4}{s: >12}{s: >10}{s: >9}\n", .{
        "codec", "method", "byte", "input", "output", "permille",
    });

    for ([_]c_int{ 0, 1 }) |order| {
        const encoded = try htscodecs.rans4x8.compress(payload, order);
        defer encoded.deinit();
        const label = if (order == 0) "order0" else "order1";
        try reportRow(out, .{ .codec = "rans4x8", .label = label, .method = order }, payload.len, encoded.len);
    }

    const rows = [_]Method{
        .{ .codec = "rans4x16", .label = "order0", .method = 0 },
        .{ .codec = "rans4x16", .label = "order1", .method = 1 },
        .{ .codec = "rans4x16", .label = "x32", .method = htscodecs.order_flag.x32 },
        .{ .codec = "rans4x16", .label = "rle", .method = htscodecs.order_flag.rle },
        .{ .codec = "rans4x16", .label = "pack", .method = htscodecs.order_flag.pack },
        .{
            .codec = "rans4x16",
            .label = "rle+pack",
            .method = htscodecs.order_flag.rle | htscodecs.order_flag.pack,
        },
        .{ .codec = "arith", .label = "order0", .method = 0 },
        .{ .codec = "arith", .label = "order1", .method = 1 },
        .{ .codec = "arith", .label = "rle", .method = htscodecs.arith_order_flag.rle },
        .{ .codec = "arith", .label = "pack", .method = htscodecs.arith_order_flag.pack },
        .{
            .codec = "arith",
            .label = "rle+pack",
            .method = htscodecs.arith_order_flag.rle | htscodecs.arith_order_flag.pack,
        },
    };

    for (rows) |row| {
        const encoded = if (std.mem.eql(u8, row.codec, "rans4x16"))
            try htscodecs.rans4x16.compress(payload, row.method)
        else
            try htscodecs.arith.compress(payload, row.method);
        defer encoded.deinit();
        try reportRow(out, row, payload.len, encoded.len);
    }
}

fn reportMatch(out: *std.Io.Writer, name: []const u8, count: usize, unit: []const u8) !void {
    try out.print("  {s: <26}{d: >8} {s: <7} match\n", .{ name, count, unit });
}

fn reportInteroperability(out: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    const payload = try q4Payload(gpa);
    defer gpa.free(payload);

    try out.print("\ndecoding upstream's own compressed fixtures (v1.6.7)\n", .{});

    for ([_]struct { name: []const u8, stream: []const u8 }{
        .{ .name = "rans4x8  q4 order 0", .stream = fx.r4x8.q4_0 },
        .{ .name = "rans4x8  q4 order 1", .stream = fx.r4x8.q4_1 },
    }) |entry| {
        const decoded = try htscodecs.rans4x8.uncompress(entry.stream);
        defer decoded.deinit();
        if (!std.mem.eql(u8, decoded.slice(), payload)) return error.OracleMismatch;
        try reportMatch(out, entry.name, decoded.len, "bytes");
    }

    for ([_]struct { name: []const u8, stream: []const u8 }{
        .{ .name = "rans4x16 q4 order 0", .stream = fx.r4x16.q4_0 },
        .{ .name = "rans4x16 q4 x32", .stream = fx.r4x16.q4_4 },
        .{ .name = "rans4x16 q4 rle", .stream = fx.r4x16.q4_64 },
        .{ .name = "rans4x16 q4 pack", .stream = fx.r4x16.q4_128 },
        .{ .name = "rans4x16 q4 rle+pack", .stream = fx.r4x16.q4_192 },
    }) |entry| {
        const decoded = try htscodecs.rans4x16.uncompress(entry.stream);
        defer decoded.deinit();
        if (!std.mem.eql(u8, decoded.slice(), payload)) return error.OracleMismatch;
        try reportMatch(out, entry.name, decoded.len, "bytes");
    }

    for ([_]struct { name: []const u8, stream: []const u8 }{
        .{ .name = "arith    q4 order 0", .stream = fx.arith.q4_0 },
        .{ .name = "arith    q4 stripe", .stream = fx.arith.q4_8 },
        .{ .name = "arith    q4 rle", .stream = fx.arith.q4_64 },
        .{ .name = "arith    q4 rle+pack", .stream = fx.arith.q4_192 },
    }) |entry| {
        const decoded = try htscodecs.arith.uncompress(entry.stream);
        defer decoded.deinit();
        if (!std.mem.eql(u8, decoded.slice(), payload)) return error.OracleMismatch;
        try reportMatch(out, entry.name, decoded.len, "bytes");
    }

    {
        // An fqzcomp block is a sequence of raw phred records, so the
        // oracle is `cut -f 1` of the corpus - the block upstream's own
        // shell test feeds the encoder (`tests/fqzcomp.test:11`) - rebuilt
        // from the record lengths the decoder reports, exactly as its test
        // driver's `puts` loop does (`tests/fqzcomp_qual_test.c:409-417`).
        const want = try fx.qualityLines(gpa, fx.source.q4);
        defer gpa.free(want);

        const records = fx.recordCount(want);
        const lengths = try gpa.alloc(c_int, records);
        defer gpa.free(lengths);

        for ([_]struct { name: []const u8, stream: []const u8 }{
            .{ .name = "fqzcomp  q4 strategy 0", .stream = fx.fqzcomp.q4_0 },
            .{ .name = "fqzcomp  q4 strategy 3", .stream = fx.fqzcomp.q4_3 },
        }) |entry| {
            const decoded = try htscodecs.fqzcomp.decompressLengths(entry.stream, lengths);
            defer decoded.deinit();
            const rebuilt = try fx.qualityRecords(gpa, decoded.slice(), lengths);
            defer gpa.free(rebuilt);
            if (!std.mem.eql(u8, rebuilt, want)) return error.OracleMismatch;
            try reportMatch(out, entry.name, records, "records");
        }
    }

    {
        const decoded = try htscodecs.tok3.decodeNames(fx.tok3.set_01_names_5);
        defer decoded.deinit();
        const rebuilt = try fx.splitNames(gpa, decoded.slice());
        defer gpa.free(rebuilt);
        if (!std.mem.eql(u8, rebuilt, fx.source.set_01_names)) {
            return error.OracleMismatch;
        }
        var names: usize = 0;
        for (decoded.slice()) |byte| {
            if (byte == 0) names += 1;
        }
        try reportMatch(out, "tok3     01.names level 5", names, "names");
    }
}

fn reportOwnership(out: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    try out.print("\nownership paths\n", .{});

    const payload = try q4Payload(gpa);
    defer gpa.free(payload);

    // Caller buffers: the destination is ours, so the library allocates
    // nothing and there is nothing to free.
    const bound = try htscodecs.rans4x16.compressBound(payload.len, 0);
    const scratch = try gpa.alloc(u8, bound);
    defer gpa.free(scratch);
    const n = try htscodecs.rans4x16.compressTo(payload, scratch, 0);

    const plain = try gpa.alloc(u8, payload.len);
    defer gpa.free(plain);
    const m = try htscodecs.rans4x16.uncompressTo(scratch[0..n], plain);
    if (m != payload.len or !std.mem.eql(u8, plain[0..m], payload)) return error.RoundTripMismatch;
    try out.print("  caller buffer : bound {d: >7}, wrote {d: >7}, read back {d: >7}, match\n", .{
        bound, n, m,
    });

    // Owned: upstream malloced the result and the C allocator frees it.
    const owned = try htscodecs.rans4x8.compress(payload, 0);
    try out.print("  Owned         : {d: >7} bytes from upstream malloc, released with free()\n", .{owned.len});
    owned.deinit();
}
