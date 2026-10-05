// SPDX-License-Identifier: BSD-3-Clause
//! Consumer of the htscodecs fork, through the public module only.
//!
//! Nothing in this file reaches into the fork's source tree, its generated
//! headers or its test fixtures.  Everything below goes through
//! `dep.module("htscodecs")` in build.zig, which is exactly what a
//! downstream project would do.
//!
//! Output is deterministic: the same payload, the same codecs, the same
//! numbers on every run and every machine.  A failed assertion is a
//! non-zero exit, so `zig build run` is a real check and not a demo.
//!
//! In a runtime-loading build (`-Druntime=true`) the fork's library is not
//! linked into this executable at all, so the provider is named explicitly:
//! `--provider <path>` on the command line or `HTSCODECS_PROVIDER` in the
//! environment.  A run told neither says so and exits non-zero.  There is no
//! default file, no search path and no fallback to a linked copy.

const std = @import("std");
const htscodecs = @import("htscodecs");

/// What this program adds to what `load` can already say.
const ConfigurationError = error{ NoProviderConfigured };

/// The environment variable naming the provider file.
const provider_variable = "HTSCODECS_PROVIDER";

/// A fixed, compressible payload that resembles a quality-score block: a
/// small alphabet over a long run, which is what CRAM actually stores.
fn makePayload(buf: []u8) []const u8 {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    for (buf, 0..) |*byte, i| {
        // A simple deterministic pattern with a short period plus a slow
        // drift, so order-0, order-1 and the run-length method all have
        // something to find.
        byte.* = alphabet[(i / 97 + i / 13) % alphabet.len];
    }
    return buf;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    defer file_writer.flush() catch {};
    const out = &file_writer.interface;

    const raw = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(raw);
    const payload = makePayload(raw);

    // A linked build has the library in the executable and needs nothing.  A
    // runtime-loading build has an empty table until a provider is named, and
    // every check below would otherwise stop the program naming itself.
    if (comptime htscodecs.runtime_loaded) {
        try htscodecs.load(.{ .path = try providerRequest(init) });
    }
    try out.print("htscodecs {s} via a real package dependency\n", .{htscodecs.versionText()});

    try checkRans4x8(out, payload);
    try checkRans4x16(out, gpa, payload);
    try checkArith(out, gpa, payload);
    try checkRans32x16(out, gpa, payload);
    try checkTok3(out, gpa);
    try checkFqzcomp(out, gpa);
    try checkRle(out, gpa, payload);
    try checkPack(out, gpa);
    try checkErrors(out);
    try checkRawC(out, gpa, payload);
    try checkQualityStats(out, payload);
    try checkProviderAllocator(out, payload);

    try out.print("\nall consumer assertions passed\n", .{});
}

fn report(out: *std.Io.Writer, name: []const u8, payload: usize, encoded: usize) !void {
    try out.print("  {s: <12}{d: >7} -> {d: >7} bytes ({d: >5} permille)  round trip ok\n", .{
        name, payload, encoded, encoded * 1000 / payload,
    });
}

/// Encodes into a caller buffer and decodes back into another one, so the
/// ownership path is entirely the caller's.
fn roundTripCallerBuffers(
    out: *std.Io.Writer,
    gpa: std.mem.Allocator,
    name: []const u8,
    payload: []const u8,
    order: c_int,
    comptime codec: enum { rans4x16, arith },
) !void {
    const bound = switch (codec) {
        .rans4x16 => try htscodecs.rans4x16.compressBound(payload.len, order),
        .arith => try htscodecs.arith.compressBound(payload.len, order),
    };
    const scratch = try gpa.alloc(u8, bound);
    defer gpa.free(scratch);

    const n = switch (codec) {
        .rans4x16 => try htscodecs.rans4x16.compressTo(payload, scratch, order),
        .arith => try htscodecs.arith.compressTo(payload, scratch, order),
    };

    const plain = try gpa.alloc(u8, payload.len);
    defer gpa.free(plain);
    const m = switch (codec) {
        .rans4x16 => try htscodecs.rans4x16.uncompressTo(scratch[0..n], plain),
        .arith => try htscodecs.arith.uncompressTo(scratch[0..n], plain),
    };

    if (m != payload.len) return error.RoundTripLengthMismatch;
    if (!std.mem.eql(u8, plain[0..m], payload)) return error.RoundTripContentMismatch;
    try report(out, name, payload.len, n);
}

fn checkRans4x8(out: *std.Io.Writer, payload: []const u8) !void {
    for ([_]c_int{ 0, 1 }) |order| {
        const encoded = try htscodecs.rans4x8.compress(payload, order);
        const back = try htscodecs.rans4x8.uncompress(encoded.slice());
        if (!std.mem.eql(u8, back.slice(), payload)) return error.RoundTripContentMismatch;
        const name = if (order == 0) "rans4x8 o0" else "rans4x8 o1";
        try report(out, name, payload.len, encoded.len);
        back.deinit();
        encoded.deinit();
    }
}

fn checkRans4x16(out: *std.Io.Writer, gpa: std.mem.Allocator, payload: []const u8) !void {
    try roundTripCallerBuffers(out, gpa, "rans4x16", payload, 0, .rans4x16);
    try roundTripCallerBuffers(out, gpa, "rans4x16 rle", payload, htscodecs.order_flag.rle, .rans4x16);
    try roundTripCallerBuffers(out, gpa, "rans4x16 pk", payload, htscodecs.order_flag.pack, .rans4x16);
}

fn checkArith(out: *std.Io.Writer, gpa: std.mem.Allocator, payload: []const u8) !void {
    try roundTripCallerBuffers(out, gpa, "arith o0", payload, 0, .arith);
    try roundTripCallerBuffers(out, gpa, "arith o1", payload, 1, .arith);
    try roundTripCallerBuffers(out, gpa, "arith rle", payload, htscodecs.arith_order_flag.rle, .arith);
}

fn checkRans32x16(out: *std.Io.Writer, gpa: std.mem.Allocator, payload: []const u8) !void {
    const plain = try gpa.alloc(u8, payload.len);
    defer gpa.free(plain);

    for ([_]c_int{ 0, 1 }) |order| {
        // The 32x16 kernels bound themselves per order and refuse a
        // smaller destination, and the order-1 bound reserves the whole
        // 256x256 order-1 frequency table, so one buffer cannot serve
        // both.
        const bound = try htscodecs.rans4x16.compressBound(payload.len, order);
        const scratch = try gpa.alloc(u8, bound);
        defer gpa.free(scratch);

        const n = try htscodecs.rans32x16.compressTo(payload, scratch, order);
        const m = try htscodecs.rans32x16.uncompressTo(scratch[0..n], plain, order);
        if (m != payload.len or !std.mem.eql(u8, plain[0..m], payload)) {
            return error.RoundTripContentMismatch;
        }
        try report(out, if (order == 0) "rans32x16 o0" else "rans32x16 o1", payload.len, n);
    }
}

fn checkTok3(out: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    const num_names = 64;
    const pattern = "SRR1234567.1 HWUSI:1:1101:{d}:1000:{d}/1\n";
    const record_size = comptime std.fmt.count(pattern, .{ num_names, 1000 + num_names - 1 });
    var names: [num_names * record_size]u8 = undefined;
    var at: usize = 0;
    for (0..num_names) |i| {
        at += (try std.fmt.bufPrint(names[at..], pattern, .{
            i + 1,
            1000 + i,
        })).len;
    }
    const template = names[0..at];

    for ([_]c_int{ 1, 5, 9, 13, 19 }) |level| {
        // encodeNames rewrites the separators to NUL in place, so the
        // template has to be copied for each level.  That the copy is
        // needed is the API's documented contract, not an accident here.
        const block = try gpa.dupe(u8, template);
        defer gpa.free(block);

        const encoded = try htscodecs.tok3.encodeNames(block, level, false, null);
        const back = try htscodecs.tok3.decodeNames(encoded.slice());
        if (back.len != template.len) return error.RoundTripLengthMismatch;
        for (back.slice(), template) |got, want| {
            if (got == 0) {
                if (want != '\n') return error.RoundTripContentMismatch;
            } else if (got != want) return error.RoundTripContentMismatch;
        }
        back.deinit();
        try report(out, "tok3", template.len, encoded.len);
        encoded.deinit();
    }
}

fn checkFqzcomp(out: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    _ = gpa;
    const records = [_][]const u8{
        "IIIIIIIIIIIIIIIIIIIIII",
        "#########",
        "GGGGGGGGGG",
    };
    var qualities: [128]u8 = undefined;
    var lens: [records.len]u32 = undefined;
    var flags: [records.len]u32 = undefined;
    var at: usize = 0;
    for (records, 0..) |record, i| {
        lens[i] = @intCast(record.len);
        flags[i] = if (i == 1) htscodecs.fqzcomp.flag_read2 else 0;
        for (record) |byte| {
            qualities[at] = byte - 33;
            at += 1;
        }
    }
    const payload = qualities[0..at];

    const slice = htscodecs.Slice{
        .num_records = records.len,
        .len = &lens,
        .flags = &flags,
    };
    const encoded = try htscodecs.fqzcomp.compress(htscodecs.fqzcomp.vers_4_0, slice, payload, 0);

    var lengths: [records.len]c_int = undefined;
    const back = try htscodecs.fqzcomp.decompressLengths(encoded.slice(), &lengths);
    if (!std.mem.eql(u8, back.slice(), payload)) return error.RoundTripContentMismatch;
    for (lens, lengths) |want, got| {
        if (@as(usize, @intCast(got)) != want) return error.RecordLengthMismatch;
    }
    try report(out, "fqzcomp", payload.len, encoded.len);
    back.deinit();
    encoded.deinit();
}

fn checkRle(out: *std.Io.Writer, gpa: std.mem.Allocator, payload: []const u8) !void {
    const run = try gpa.alloc(u8, payload.len);
    defer gpa.free(run);
    const encoded = try gpa.alloc(u8, 2 * payload.len);
    defer gpa.free(encoded);
    const plain = try gpa.alloc(u8, payload.len);
    defer gpa.free(plain);

    var syms = htscodecs.rle.Symbols{};
    const written = try htscodecs.rle.encode(payload, run, &syms, encoded);
    const m = try htscodecs.rle.decode(
        encoded[0..written.out_len],
        run[0..written.run_len],
        &syms,
        plain,
    );
    if (m != payload.len or !std.mem.eql(u8, plain[0..m], payload)) {
        return error.RoundTripContentMismatch;
    }
    try report(out, "rle", payload.len, written.out_len);
}

fn checkPack(out: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    _ = gpa;
    var data: [1000]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = "ACGT"[i % 4];

    var meta = htscodecs.pack.Meta{};
    const encoded = try htscodecs.pack.packData(&data, &meta);

    var map: [256]u8 = @splat(0);
    const header = try htscodecs.pack.unpackMeta(meta.map[0..], @intCast(data.len), map[0..]);

    var plain: [1000]u8 = undefined;
    const m = try htscodecs.pack.unpackTo(encoded.slice(), &plain, header.nsym, map[0..]);
    if (m != data.len or !std.mem.eql(u8, plain[0..m], &data)) {
        return error.RoundTripContentMismatch;
    }
    try report(out, "pack", data.len, encoded.len);
    encoded.deinit();
}

fn checkErrors(out: *std.Io.Writer) !void {
    const empty: []const u8 = &.{};
    // The documented error surface, not a crash and not silent garbage.
    // Upstream's NULL carries no reason, so the facade reports the neutral
    // error.OperationFailed rather than guessing at a diagnosis.
    if (htscodecs.rans4x8.uncompress(empty)) |owned| {
        owned.deinit();
        return error.EmptyInputAccepted;
    } else |err| {
        if (err != htscodecs.Error.OperationFailed) return error.UnexpectedError;
    }
    if (htscodecs.tok3.decodeNames(empty)) |owned| {
        owned.deinit();
        return error.EmptyInputAccepted;
    } else |err| {
        if (err != htscodecs.Error.OperationFailed) return error.UnexpectedError;
    }

    // An argument the facade checks itself gets a specific name, and here
    // it is a diagnostic error: a symbol map one byte too short.
    var packed_meta = [_]u8{0} ** 256;
    const short_map = packed_meta[0 .. packed_meta.len - 1];
    if (htscodecs.pack.unpackMeta(&packed_meta, 1, short_map)) |_| {
        return error.ShortMapAccepted;
    } else |err| {
        if (err != htscodecs.Error.InvalidArgument) return error.UnexpectedError;
    }

    // The run-length symbol count is the other pre-call refusal worth
    // proving from a downstream package: upstream indexes a 256-byte
    // array with the caller's own count and checks nothing, so the facade
    // has to range-check it before C sees it, in both directions.
    const rle_data: []const u8 = "abcdefgh";
    var run = [_]u8{0} ** 8;
    var encoded = [_]u8{0} ** 8;
    var decoded = [_]u8{0} ** 8;
    var syms = htscodecs.rle.Symbols{};
    syms.count = 257;
    if (htscodecs.rle.encode(rle_data, &run, &syms, &encoded)) |_| {
        return error.BadSymbolCountAccepted;
    } else |err| {
        if (err != htscodecs.Error.InvalidArgument) return error.UnexpectedError;
    }
    if (htscodecs.rle.decode(&encoded, &run, &syms, &decoded)) |_| {
        return error.BadSymbolCountAccepted;
    } else |err| {
        if (err != htscodecs.Error.InvalidArgument) return error.UnexpectedError;
    }

    try out.print(
        "  {s: <12}empty input -> error.OperationFailed; short map and symbol count 257 -> error.InvalidArgument\n",
        .{"errors"},
    );
}

fn checkRawC(out: *std.Io.Writer, gpa: std.mem.Allocator, payload: []const u8) !void {
    _ = gpa;
    // The translated C interface is reachable directly, for anything the
    // facade does not wrap.  This also proves the C artifact is linked into
    // a plain downstream executable.
    const c = htscodecs.c;
    var out_size: c_uint = 0;
    const raw = c.rans_compress_4x16(
        @ptrCast(@constCast(payload.ptr)),
        @intCast(payload.len),
        &out_size,
        0,
    );
    // A C declaration returning `unsigned char *` translates to a
    // non-optional `[*c]u8`; widening it to an optional is how the NULL the
    // C contract allows is asked about, and `orelse` on the C pointer
    // itself would not type-check.
    const maybe_raw: ?[*c]u8 = raw;
    if (maybe_raw == null) return error.RawCompressFailed;
    // Upstream malloced this; the package documents cFree as the matching
    // release, and it is the same allocator either way.
    defer htscodecs.cFree(@ptrCast(maybe_raw));

    var back_size: c_uint = 0;
    const back = c.rans_uncompress_4x16(
        @ptrCast(raw),
        out_size,
        &back_size,
    );
    const maybe_back: ?[*c]u8 = back;
    if (maybe_back == null) return error.RawUncompressFailed;
    defer htscodecs.cFree(@ptrCast(maybe_back));

    if (back_size != payload.len) return error.RawRoundTripLengthMismatch;
    if (!std.mem.eql(u8, back[0..back_size], payload)) return error.RawRoundTripContentMismatch;

    try out.print("  {s: <12}raw C rans_compress_4x16 / rans_uncompress_4x16 round trip ok\n", .{"c module"});
}

/// The fqzcomp analysis utility, checked through its own result rather than
/// against a fixture: the histogram it fills must account for every quality
/// byte handed in, and the parameter block it fills must report the same
/// number of distinct symbols the histogram shows.
fn checkQualityStats(out: *std.Io.Writer, payload: []const u8) !void {
    // `qualStats` reads `slice.flags[rec]` before it checks
    // `rec < num_records`, so the facade requires one entry more than there
    // are records.  The extra entry is never required to mean anything.
    var lengths = [_]u32{ @intCast(payload.len), 0 };
    var flags = [_]u32{ 0, 0 };
    const slice = htscodecs.Slice{
        .num_records = 1,
        .len = &lengths,
        .flags = &flags,
    };

    var params: htscodecs.c.fqz_param = std.mem.zeroes(htscodecs.c.fqz_param);
    var histogram = [_]u32{0} ** 256;
    try htscodecs.fqzcomp.qualStats(slice, payload, &params, &histogram, -1);

    var counted: u64 = 0;
    var distinct: c_int = 0;
    for (histogram) |count| {
        counted += count;
        if (count != 0) distinct += 1;
    }
    if (counted != payload.len) return error.HistogramTotalMismatch;
    if (params.nsym != distinct) return error.HistogramSymbolMismatch;
    // `max_sym` is the highest symbol the histogram actually saw, so its bin
    // is non-empty and every bin above it is not.
    if (params.max_sym < 0 or params.max_sym > 255) return error.HistogramSymbolRange;
    // `fqz_param.max_sym` is upstream's `int`, while a histogram bin is a
    // Zig index, so the range check above is what makes this cast sound and
    // the annotated type is what gives it a result type.
    const max_sym: usize = @intCast(params.max_sym);
    if (histogram[max_sym] == 0) return error.HistogramMaxSymbolEmpty;
    for (histogram[max_sym + 1 ..]) |count| {
        if (count != 0) return error.HistogramMaxSymbolNotHighest;
    }

    try out.print(
        "  {s: <12}fqzcomp.qualStats accounted for {d} bytes as {d} distinct symbols, max {d}\n",
        .{ "quality stats", counted, distinct, params.max_sym },
    );
}

/// The provider's own allocation pool, used the way a caller is meant to use
/// it: allocated from the pool, written by a codec, and released through the
/// pool's own free rather than libc's.
fn checkProviderAllocator(out: *std.Io.Writer, payload: []const u8) !void {
    const bound = try htscodecs.rans4x16.compressBound(payload.len, 0);
    const scratch = try htscodecs.tls.alloc(bound);
    defer htscodecs.tls.free(scratch);

    // The pool's contents are unspecified: a fresh block is zeroed and a
    // reused one is not (`utils.c:141-162`), so what this writes and reads
    // back is real memory rather than a non-null pointer, and the check
    // below is that the round trip is byte-exact.
    const n = try htscodecs.rans4x16.compressTo(payload, scratch[0..bound], 0);

    const plain = try htscodecs.tls.alloc(payload.len);
    defer htscodecs.tls.free(plain);
    const m = try htscodecs.rans4x16.uncompressTo(scratch[0..n], plain[0..payload.len]);
    if (m != payload.len) return error.PoolRoundTripLengthMismatch;
    if (!std.mem.eql(u8, plain[0..m], payload)) return error.PoolRoundTripContentMismatch;

    // A second block from the same pool must be a different allocation: the
    // threaded pool is a cache of real blocks, not a bump allocator handing
    // the same bytes out twice.
    const second = try htscodecs.tls.alloc(bound);
    defer htscodecs.tls.free(second);
    if (second == scratch) return error.PoolReusedLiveBlock;

    try out.print(
        "  {s: <12}{d} bytes compressed into provider pool memory and back, released with htscodecs_tls_free\n",
        .{ "pool", payload.len },
    );
}

/// The provider this run should load, from `--provider <path>` or from
/// `HTSCODECS_PROVIDER`.
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
/// next person into the loader instead of to their command line.
fn noProvider() ConfigurationError {
    std.debug.print(
        "htscodecs consumer: this is a runtime-loading build, so nothing is " ++
            "linked and every codec call needs a provider first.  Pass " ++
            "--provider <path>, or export {s} with a shared object exporting " ++
            "every entry point of the installed htscodecs headers.  Nothing is " ++
            "loaded by default and no other file is tried.\n",
        .{provider_variable},
    );
    return error.NoProviderConfigured;
}
