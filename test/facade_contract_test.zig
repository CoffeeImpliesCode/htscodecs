//! Contracts of the facade itself: the guards it owns, length narrowing,
//! and the run-time kernel selection.
//!
//! What is deliberately *not* here: pinning the version string or a default
//! constant, and asserting that declarations exist.  Both belong to
//! `zig build provenance` and to the smoke report, not to a test that can
//! only ever pass.

const std = @import("std");
const htscodecs = @import("htscodecs");
const provider = @import("provider.zig");

const Error = htscodecs.Error;

/// Long enough to exercise every order and method the facade advertises.
const payload = "the quick brown fox jumps over the lazy dog, " ++
    "and then does it again, and again, and again";

test "a length that does not fit upstream's unsigned int is refused before the call" {
    try provider.load();
    // A slice header claiming more than 2 GiB.  No byte is ever read: the
    // narrowing check fires first, which is exactly the point of it.  If
    // the check were removed this test would read out of bounds, so it
    // asserts something real about the guard rather than about the error
    // type alone.
    var anchor: [1]u8 = .{0};
    const oversized = @as([*]const u8, @ptrCast(&anchor))[0 .. htscodecs.max_stream_len + 1];
    // The same claim, mutable, for the two entry points that take `[]u8`.
    const oversized_mut = @as([*]u8, @ptrCast(&anchor))[0 .. htscodecs.max_stream_len + 1];

    try std.testing.expectError(Error.LengthOverflow, htscodecs.rans4x8.compress(oversized, 0));
    try std.testing.expectError(Error.LengthOverflow, htscodecs.rans4x16.compress(oversized, 0));
    try std.testing.expectError(Error.LengthOverflow, htscodecs.rans4x16.uncompress(oversized));
    try std.testing.expectError(Error.LengthOverflow, htscodecs.arith.compress(oversized, 0));
    try std.testing.expectError(Error.LengthOverflow, htscodecs.arith.uncompress(oversized));
    try std.testing.expectError(Error.LengthOverflow, htscodecs.tok3.encodeNames(oversized_mut, 5, false, null));
    // NOT tok3.decodeNames here.  Its length argument is upstream's
    // `uint32_t`, so the narrowing check that guards every other entry
    // point does not fire for a `max_stream_len` slice, and the call would
    // hand C a fabricated two-gigabyte range and read unallocated memory.
    // Its real refusal is exercised by the test below.

    var slice_len = [_]u32{0};
    var slice_flags = [_]u32{0};
    try std.testing.expectError(Error.LengthOverflow, htscodecs.fqzcomp.compress(
        htscodecs.fqzcomp.vers_4_0,
        .{ .num_records = 1, .len = &slice_len, .flags = &slice_flags },
        oversized_mut,
        0,
    ));

    var meta = htscodecs.pack.Meta{};
    try std.testing.expectError(Error.LengthOverflow, htscodecs.pack.packData(oversized, &meta));

    var scratch: [64]u8 = undefined;
    try std.testing.expectError(Error.LengthOverflow, htscodecs.rans4x16.uncompressTo(oversized, &scratch));
    try std.testing.expectError(Error.LengthOverflow, htscodecs.arith.uncompressTo(oversized, &scratch));
}

test "fqzcomp refuses a negative strategy before native table access" {
    try provider.load();
    var qualities = [_]u8{ 10, 20, 30, 40 };
    var lengths = [_]u32{qualities.len};
    var flags = [_]u32{0};
    try std.testing.expectError(Error.InvalidArgument, htscodecs.fqzcomp.compress(
        htscodecs.fqzcomp.vers_4_0,
        .{ .num_records = 1, .len = &lengths, .flags = &flags },
        &qualities,
        -1,
    ));
}

test "fqzcomp narrows the record count before adding sentinel capacity" {
    try provider.load();
    var lengths: [0]u32 = .{};
    var flags: [0]u32 = .{};
    var params = std.mem.zeroes(htscodecs.c.fqz_param);
    var histogram: [256]u32 = @splat(0);
    try std.testing.expectError(Error.LengthOverflow, htscodecs.fqzcomp.qualStats(
        .{ .num_records = std.math.maxInt(usize), .len = &lengths, .flags = &flags },
        &.{},
        &params,
        &histogram,
        -1,
    ));
}

test "an undecodable name block reports the C failure instead of guessing" {
    try provider.load();
    // Four bytes cannot carry the header `tok3_decode_names` reads before
    // it looks at anything else: `if (sz < 9) return NULL`
    // (tokenise_name3.c:1678-1679).  The wrapper has to report that as an
    // error rather than dereference the null pointer the C contract
    // allows.
    try std.testing.expectError(Error.OperationFailed, htscodecs.tok3.decodeNames(&.{ 0, 1, 2, 3 }));
}

test "the two buffer paths agree byte for byte and both stay inside the bound" {
    try provider.load();
    const rans_bound = try htscodecs.rans4x16.compressBound(payload.len, 0);
    const rans_scratch = try std.testing.allocator.alloc(u8, rans_bound);
    defer std.testing.allocator.free(rans_scratch);
    const rans_n = try htscodecs.rans4x16.compressTo(payload, rans_scratch, 0);
    try std.testing.expect(rans_n <= rans_bound);

    const arith_bound = try htscodecs.arith.compressBound(payload.len, 0);
    const arith_scratch = try std.testing.allocator.alloc(u8, arith_bound);
    defer std.testing.allocator.free(arith_scratch);
    const arith_n = try htscodecs.arith.compressTo(payload, arith_scratch, 0);
    try std.testing.expect(arith_n <= arith_bound);

    // The allocating forms must produce exactly what the caller-buffer
    // forms produced.  This is the check that catches a wrapper which
    // forgets to write back the used length.
    const rans_owned = try htscodecs.rans4x16.compress(payload, 0);
    defer rans_owned.deinit();
    try std.testing.expectEqual(rans_n, rans_owned.len);
    try std.testing.expectEqualSlices(u8, rans_scratch[0..rans_n], rans_owned.slice());

    const arith_owned = try htscodecs.arith.compress(payload, 0);
    defer arith_owned.deinit();
    try std.testing.expectEqual(arith_n, arith_owned.len);
    try std.testing.expectEqualSlices(u8, arith_scratch[0..arith_n], arith_owned.slice());

    // Nothing here asserts that the two codecs emit *different* bytes.  That
    // is a claim about the encoders' internals rather than about anything a
    // caller can rely on, and it would break on an upstream implementation
    // change that is not a bug.  The path equivalence above is the
    // contract; the interoperability fixtures are the correctness oracle.
}

test "every kernel setting still round trips" {
    try provider.load();
    // rans_set_cpu assigns its argument outright, so zero means "no 32x16
    // kernel" and 0xFFFF is what restores automatic selection.  A facade
    // that got this backwards would show up as a broken round trip in one
    // of the two configurations, not as a silent difference.
    for ([_]struct { name: []const u8, mask: c_int }{
        .{ .name = "automatic", .mask = htscodecs.cpu_flag.all },
        .{ .name = "scalar only", .mask = htscodecs.cpu_flag.none },
        .{ .name = "x86 decode only", .mask = htscodecs.cpu_flag.dec_sse4 },
        .{ .name = "neon encode only", .mask = htscodecs.cpu_flag.enc_neon },
    }) |setting| {
        htscodecs.ransSetCpu(setting.mask);

        const encoded = try htscodecs.rans4x16.compress(payload, 0);
        defer encoded.deinit();

        const back = try htscodecs.rans4x16.uncompress(encoded.slice());
        defer back.deinit();
        try std.testing.expectEqualSlices(u8, payload, back.slice());

        // The mask is global, so leave the library as it was found.
        htscodecs.ransSetCpu(htscodecs.cpu_flag.all);
    }
}

test "overlapping input and destination are refused before the C call" {
    try provider.load();
    // The guard is an ordinary comparison rather than a debug assertion,
    // so it holds in ReleaseFast too.  Upstream reads one region while
    // writing the other; letting a caller overlap them would make the
    // result depend on the order the C code happens to touch the bytes.
    var buffer: [512]u8 = @splat(0);
    const head = buffer[0..256];
    const tail = buffer[128..];

    try std.testing.expectError(
        Error.InvalidArgument,
        htscodecs.rans4x16.compressTo(head, tail, 0),
    );
    try std.testing.expectError(
        Error.InvalidArgument,
        htscodecs.arith.compressTo(head, tail, 0),
    );

    // The same overlap on the decode side, where both buffers are the
    // caller's own.
    const encoded = try htscodecs.rans4x16.compress(head, 0);
    defer encoded.deinit();
    var scratch: [1024]u8 = @splat(0);
    @memcpy(scratch[0..encoded.len], encoded.slice());
    try std.testing.expectError(
        Error.InvalidArgument,
        htscodecs.rans4x16.uncompressTo(scratch[0..encoded.len], scratch[0..]),
    );
}

test "the run-length encoder refuses a destination it would overrun" {
    try provider.load();
    // Upstream bounds neither buffer, so the facade owns the bound it
    // documents: one literal per input byte into `out`, one varint per run
    // into `run`.
    var data: [512]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = if (i % 2 == 0) 'A' else 'B';
    var run: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    var syms = htscodecs.rle.Symbols{};

    var short_out: [511]u8 = undefined;
    try std.testing.expectError(
        Error.BufferTooSmall,
        htscodecs.rle.encode(&data, &run, &syms, &short_out),
    );

    var short_run: [511]u8 = undefined;
    try std.testing.expectError(
        Error.BufferTooSmall,
        htscodecs.rle.encode(&data, &short_run, &syms, &out),
    );

    // Exactly the documented bound is the case that has to work, and the
    // stream it produces has to read back exactly.
    const written = try htscodecs.rle.encode(&data, &run, &syms, &out);
    var back: [512]u8 = undefined;
    const n = try htscodecs.rle.decode(
        out[0..written.out_len],
        run[0..written.run_len],
        &syms,
        &back,
    );
    try std.testing.expectEqual(data.len, n);
    try std.testing.expectEqualSlices(u8, &data, &back);
}

test "the run-length symbol count is refused outside 0..256, in both directions" {
    try provider.load();
    // Upstream indexes the 256-byte `rle_syms` array with the caller's own
    // count on both sides - `rle.c:112-114` encodes, `rle.c:155-156`
    // decodes - and the encode loop compares against it with a `uint64_t`
    // index, so a negative count does not wrap around but runs off the
    // end.  257 comes first so the small boundary is the one observed
    // first; -1 follows for the guarded build.
    //
    // `error.InvalidArgument` is not something upstream can return - its
    // NULL is `OperationFailed` - so seeing it is proof the facade refused
    // the call.  The byte comparisons then show the buffers the C entry
    // points write are untouched.  Ordinary stack arrays: no padded
    // fixture, no allocation.
    var data: [64]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = if (i < 32) 'A' else 'B';

    var run: [64]u8 = @splat(0x11);
    var out: [64]u8 = @splat(0x22);
    const run_before = run;
    const out_before = out;

    for ([_]c_int{ 257, -1 }) |count| {
        const zero = htscodecs.rle.Symbols{};
        var syms = zero;
        syms.count = count;

        try std.testing.expectError(
            Error.InvalidArgument,
            htscodecs.rle.encode(&data, &run, &syms, &out),
        );
        try std.testing.expectEqualSlices(u8, &run_before, &run);
        try std.testing.expectEqualSlices(u8, &out_before, &out);
        try std.testing.expectEqualSlices(u8, zero.syms[0..], syms.syms[0..]);

        var decoded: [64]u8 = @splat(0x33);
        const decoded_before = decoded;
        try std.testing.expectError(
            Error.InvalidArgument,
            htscodecs.rle.decode(&out, &run, &syms, &decoded),
        );
        try std.testing.expectEqualSlices(u8, &decoded_before, &decoded);
        try std.testing.expectEqualSlices(u8, zero.syms[0..], syms.syms[0..]);
    }
}

test "the run-length symbol count accepts both ends of 0..256" {
    try provider.load();
    // 0 on entry asks the encoder to survey the data and fill both fields
    // in (`rle.c:115-118`); the decoder needs that answer to read the
    // stream back, so the lower end of the range is a real stream.
    var data: [64]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = if (i < 32) 'A' else 'B';

    var survey = htscodecs.rle.Symbols{};
    var run: [64]u8 = undefined;
    var out: [64]u8 = undefined;
    const written = try htscodecs.rle.encode(&data, &run, &survey, &out);
    try std.testing.expect(survey.count >= 1 and survey.count <= 256);

    var back: [64]u8 = undefined;
    const n = try htscodecs.rle.decode(
        out[0..written.out_len],
        run[0..written.run_len],
        &survey,
        &back,
    );
    try std.testing.expectEqual(data.len, n);
    try std.testing.expectEqualSlices(u8, &data, &back);

    // 256 is the last accepted count.  Marking every symbol makes each
    // contiguous stretch of a repeated byte one emitted run - two of them
    // here - so the top of the range is exercised on the run path instead
    // of on a stream that never uses the symbol set.
    var all = htscodecs.rle.Symbols{};
    for (&all.syms, 0..) |*sym, i| sym.* = @intCast(i);
    all.count = 256;

    var all_run: [64]u8 = undefined;
    var all_out: [64]u8 = undefined;
    const all_written = try htscodecs.rle.encode(&data, &all_run, &all, &all_out);

    var all_back: [64]u8 = undefined;
    const all_n = try htscodecs.rle.decode(
        all_out[0..all_written.out_len],
        all_run[0..all_written.run_len],
        &all,
        &all_back,
    );
    try std.testing.expectEqual(data.len, all_n);
    try std.testing.expectEqualSlices(u8, &data, &all_back);
}

test "the provider's own pool is a separate family with its own free" {
    try provider.load();
    // The pool's contents are unspecified: a fresh block is zeroed and a
    // reused one carries whatever its previous user left (`utils.c:141-162`),
    // so what this test can check about a block is its identity and the fact
    // that it is real writable memory, not what was in it.
    const block = try htscodecs.tls.alloc(4096);
    defer htscodecs.tls.free(block);
    block[0] = 0xa5;
    block[4095] = 0x5a;
    if (block[0] != 0xa5 or block[4095] != 0x5a) return error.PoolNotWritable;

    // A second live block is a second allocation.  The threaded pool is a
    // cache of real blocks, not a bump allocator, so handing the same
    // address out twice while the first is live would be a defect here.
    const other = try htscodecs.tls.alloc(4096);
    defer htscodecs.tls.free(other);
    if (other == block) return error.PoolReusedLiveBlock;

    // `calloc` is a distinct entry point from `alloc`: it multiplies before it
    // allocates.  A caller that relies on it for zeroed bytes has to be able
    // to rely on it, so this is the one call whose documented contents are
    // checked.
    const many = try htscodecs.tls.calloc(16, 256);
    defer htscodecs.tls.free(many);
    for (many[0 .. 16 * 256]) |byte| {
        if (byte != 0) return error.CallocNotZeroed;
    }

    // Memory from the pool is ordinary writable memory as far as a codec is
    // concerned, so a round trip through it must reproduce the input.
    const bound = try htscodecs.rans4x16.compressBound(payload.len, 0);
    const scratch = try htscodecs.tls.alloc(bound);
    defer htscodecs.tls.free(scratch);
    const n = try htscodecs.rans4x16.compressTo(payload, scratch[0..bound], 0);
    const plain = try htscodecs.tls.alloc(payload.len);
    defer htscodecs.tls.free(plain);
    const m = try htscodecs.rans4x16.uncompressTo(scratch[0..n], plain[0..payload.len]);
    try std.testing.expectEqual(payload.len, m);
    try std.testing.expectEqualSlices(u8, payload, plain[0..m]);
}

test "fqzcomp quality statistics account for every byte and name the symbols" {
    try provider.load();
    // Upstream reads `slice.flags[rec]` before it checks `rec < num_records`
    // (`fqzcomp_qual.c:411`), so a pair sized exactly `num_records` is one
    // entry short of what it reads.  The facade refuses it before the call,
    // in every build mode.
    var exact_len = [_]u32{@intCast(payload.len)};
    var exact_flags = [_]u32{0};
    const short = htscodecs.Slice{
        .num_records = 1,
        .len = &exact_len,
        .flags = &exact_flags,
    };
    // The refusal happens before either out-parameter is read, so they can be
    // anything; real blocks keep the call honest about its signature.
    var spare_params: htscodecs.c.fqz_param = std.mem.zeroes(htscodecs.c.fqz_param);
    var spare_histogram: [256]u32 = @splat(0);
    try std.testing.expectError(
        Error.InvalidArgument,
        htscodecs.fqzcomp.qualStats(short, payload, &spare_params, &spare_histogram, -1),
    );

    var lengths = [_]u32{ @intCast(payload.len), 0 };
    var flags = [_]u32{ 0, 0 };
    const slice = htscodecs.Slice{
        .num_records = 1,
        .len = &lengths,
        .flags = &flags,
    };

    // `do_qa` is read before anything else (`fqzcomp_qual.c:481`), so the
    // parameter block has to be the caller's to initialise.
    var params: htscodecs.c.fqz_param = std.mem.zeroes(htscodecs.c.fqz_param);
    var histogram: [256]u32 = @splat(0);
    try htscodecs.fqzcomp.qualStats(slice, payload, &params, &histogram, -1);

    var counted: u64 = 0;
    var distinct: c_int = 0;
    for (histogram) |count| {
        counted += count;
        if (count != 0) distinct += 1;
    }
    try std.testing.expectEqual(@as(u64, payload.len), counted);
    // `nsym` is the count of bins the histogram actually filled
    // (`fqzcomp_qual.c:473`-`:477`), so the two must agree by construction.
    try std.testing.expectEqual(distinct, params.nsym);
    // `max_sym` is the highest such symbol, so its bin is full and every bin
    // above it is empty.
    // `max_sym` is upstream's `int` (`htscodecs/fqzcomp_qual.h:106`), and the
    // histogram is indexed by it, so the cast needs its result type stated.
    const max_sym: usize = @intCast(params.max_sym);
    try std.testing.expect(histogram[max_sym] != 0);
    for (histogram[max_sym + 1 ..]) |count| {
        try std.testing.expectEqual(@as(u32, 0), count);
    }
}
