//! Contracts of the facade itself: the guards it owns, length narrowing,
//! and the run-time kernel selection.
//!
//! What is deliberately *not* here: pinning the version string or a default
//! constant, and asserting that declarations exist.  Both belong to
//! `zig build provenance` and to the smoke report, not to a test that can
//! only ever pass.

const std = @import("std");
const htscodecs = @import("htscodecs");

const Error = htscodecs.Error;

/// Long enough to exercise every order and method the facade advertises.
const payload = "the quick brown fox jumps over the lazy dog, " ++
    "and then does it again, and again, and again";

test "a length that does not fit upstream's unsigned int is refused before the call" {
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

test "an undecodable name block reports the C failure instead of guessing" {
    // Four bytes cannot carry the header `tok3_decode_names` reads before
    // it looks at anything else: `if (sz < 9) return NULL`
    // (tokenise_name3.c:1678-1679).  The wrapper has to report that as an
    // error rather than dereference the null pointer the C contract
    // allows.
    try std.testing.expectError(Error.OperationFailed, htscodecs.tok3.decodeNames(&.{ 0, 1, 2, 3 }));
}

test "the two buffer paths agree byte for byte and both stay inside the bound" {
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
