// SPDX-License-Identifier: BSD-3-Clause
//! Runnable demonstration of the htscodecs facade.
//!
//! `zig build smoke` runs this and prints a fixed report: the same inputs,
//! the same codecs, the same numbers, every time.  Nothing here depends on
//! timing, addresses, environment or the file system.  A mismatch against
//! an upstream fixture is a hard error, not a printed warning, so the smoke
//! step fails loudly if the library stops being interoperable.
//!
//! In a runtime-loading build (`-Druntime=true`) nothing is linked, so the
//! provider is named explicitly: `--provider <path>` on the command line or
//! `HTSCODECS_PROVIDER` in the environment.  A run that was told neither says
//! so and fails; there is no default file, no search path and no fallback to
//! a linked copy.

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

/// What this program adds to what `load` can already say.
const ConfigurationError = error{NoProviderConfigured};

/// The environment variable naming the provider file.
const provider_variable = "HTSCODECS_PROVIDER";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    defer file_writer.flush() catch {};
    const out = &file_writer.interface;

    // A linked build has the library in the binary and needs nothing.  A
    // runtime-loading build has an empty table until a provider is named, and
    // every call below would otherwise stop the program naming itself.
    if (comptime htscodecs.runtime_loaded) {
        try htscodecs.load(.{ .path = try providerRequest(init) });
    }

    try out.print("htscodecs {s} (packed version {d}, {s} build)\n\n", .{
        htscodecs.versionText(),
        htscodecs.version(),
        if (htscodecs.runtime_loaded) "runtime-loaded" else "linked",
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

    // The library's own pool is a different family with a different pairing:
    // what `tls.alloc` returns is released with `tls.free`, and libc `free`
    // is never the right releaser for it.  Compressing into provider memory
    // and reading it back is what shows the bytes are real and writable, not
    // that a pointer came back non-null.
    const pool_bound = try htscodecs.rans4x16.compressBound(payload.len, 0);
    const pool_scratch = try htscodecs.tls.alloc(pool_bound);
    defer htscodecs.tls.free(pool_scratch);
    const pool_len = try htscodecs.rans4x16.compressTo(payload, pool_scratch[0..pool_bound], 0);

    const pool_plain = try htscodecs.tls.alloc(payload.len);
    defer htscodecs.tls.free(pool_plain);
    const pool_read = try htscodecs.rans4x16.uncompressTo(pool_scratch[0..pool_len], pool_plain[0..payload.len]);
    if (pool_read != payload.len or !std.mem.eql(u8, pool_plain[0..pool_read], payload)) {
        return error.RoundTripMismatch;
    }
    try out.print("  provider pool : {d: >7} + {d: >7} bytes from htscodecs_tls_alloc, released with htscodecs_tls_free\n", .{
        pool_bound, payload.len,
    });

    // Only a runtime-loading build has a request to report, and only the
    // generated dispatch has the function to ask: a linked build's `c` is
    // the translated header and declares no `loadedSource` at all, so the
    // call is inside the branch that drops it there.
    if (comptime htscodecs.runtime_loaded) {
        try out.print("\n  loaded source : {?s}\n", .{
            if (htscodecs.loadedSource()) |source| switch (source) {
                .path => |p| p,
                .system => |s| s,
            } else null,
        });
    }
}

/// The provider this run should load, from `--provider <path>` or from
/// `HTSCODECS_PROVIDER`.
///
/// Both are explicit.  Nothing here looks in a default location or falls back
/// to a linked copy: a runtime-loading build that was not told which file to
/// load reports that it was not told, rather than loading something else.
fn providerRequest(init: std.process.Init) ConfigurationError![]const u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch
        return noProvider();
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--provider")) {
            if (index + 1 >= args.len) return noProvider();
            return args[index + 1];
        }
    }
    return init.environ_map.get(provider_variable) orelse
        return noProvider();
}

/// Say which variable is missing.  An error name on its own would send the
/// next person into the loader instead of to the command line.
fn noProvider() ConfigurationError {
    std.debug.print(
        "htscodecs demo: this is a runtime-loading build, so nothing is linked " ++
            "and every codec call needs a provider first.  Pass --provider " ++
            "<path>, or export {s} with a shared object exporting every entry " ++
            "point of the installed htscodecs headers.  Nothing is loaded by " ++
            "default and no other file is tried.\n",
        .{provider_variable},
    );
    return error.NoProviderConfigured;
}
