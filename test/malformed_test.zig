//! Bounded behaviour on malformed compressed data.
//!
//! Two properties are asserted, and only the two upstream actually
//! guarantees after years of fuzzing:
//!
//!   1. A stream too short to carry its own framing is rejected.  Those are
//!      hard length checks in the C code (`in_size < 9` for rANS 4x8 and
//!      the tokeniser, `in_size == 0` for rANS 4x16 and the arithmetic
//!      coder), so `error.OperationFailed` is the documented answer.
//!   2. A damaged stream never yields the original bytes.  Truncation or a
//!      single flipped byte may legitimately decode to *something*, but it
//!      must not decode to the input, and it must not crash.  Asserting
//!      "always an error" would claim more than the format promises: these
//!      are entropy coders over a raw byte stream, so a corrupted block can
//!      produce a shorter valid-looking block.
//!
//! Every destination here is sized from the fixture, so a malformed header
//! cannot make the library allocate wildly inside this test.

const std = @import("std");
const htscodecs = @import("htscodecs");
const fx = @import("fixtures");
const provider = @import("provider.zig");

const Error = htscodecs.Error;

const Decoder = enum {
    rans4x16,
    arith,

    fn decode(self: Decoder, compressed: []const u8, out: []u8) Error!usize {
        return switch (self) {
            .rans4x16 => htscodecs.rans4x16.uncompressTo(compressed, out),
            .arith => htscodecs.arith.uncompressTo(compressed, out),
        };
    }
};

const q8_payload_bytes = fx.source.q8.len;

test "empty input is rejected by every decoder with a framing length check" {
    try provider.load();
    const empty: []const u8 = &.{};

    try std.testing.expectError(Error.OperationFailed, htscodecs.rans4x8.uncompress(empty));
    try std.testing.expectError(Error.OperationFailed, htscodecs.rans4x16.uncompress(empty));
    try std.testing.expectError(Error.OperationFailed, htscodecs.arith.uncompress(empty));
    try std.testing.expectError(Error.OperationFailed, htscodecs.tok3.decodeNames(empty));
}

test "input shorter than the framing header is rejected" {
    try provider.load();
    var scratch: [512]u8 = undefined;

    // rANS 4x8 and the tokeniser both require at least 9 bytes.
    const runt = fx.r4x8.q4_0[0..8];
    try std.testing.expectError(Error.OperationFailed, htscodecs.rans4x8.uncompress(runt));
    try std.testing.expectError(Error.OperationFailed, htscodecs.tok3.decodeNames(runt));

    for ([_]Decoder{ .rans4x16, .arith }) |decoder| {
        try std.testing.expectError(
            Error.OperationFailed,
            decoder.decode(fx.r4x8.q4_0[0..8], &scratch),
        );
        try std.testing.expectError(
            Error.OperationFailed,
            decoder.decode(fx.arith.q4_0[0..8], &scratch),
        );
    }
}

/// Decodes `compressed` into a buffer exactly the size of `original`.
/// Returns true when the result is the original, false when upstream
/// rejected the stream, and fails when a truncated stream still decoded to
/// the input.
fn truncationReproduces(
    decoder: Decoder,
    compressed: []const u8,
    original: []const u8,
) !bool {
    const buf = try std.testing.allocator.alloc(u8, original.len);
    defer std.testing.allocator.free(buf);
    if (decoder.decode(compressed, buf)) |n| {
        return std.mem.eql(u8, buf[0..n], original);
    } else |err| {
        try std.testing.expectEqual(Error.OperationFailed, err);
        return false;
    }
}

test "truncating a checked-in stream never reproduces the original" {
    try provider.load();
    const raw = try std.testing.allocator.alloc(u8, q8_payload_bytes);
    defer std.testing.allocator.free(raw);
    const original = fx.qualityPayload(fx.source.q8, raw);

    const cases = [_]struct { decoder: Decoder, stream: []const u8 }{
        .{ .decoder = .rans4x16, .stream = fx.r4x16.q8_0 },
        .{ .decoder = .arith, .stream = fx.arith.q8_0 },
    };

    for (cases) |case| {
        for ([_]usize{ 1, 2, 3 }) |part| {
            const cut = case.stream.len * part / 4;
            if (cut == 0 or cut >= case.stream.len) continue;
            if (try truncationReproduces(case.decoder, case.stream[0..cut], original)) {
                std.debug.print(
                    "truncating a {d}-byte stream to {d} bytes still decoded to the original\n",
                    .{ case.stream.len, cut },
                );
                return error.TruncationReproducedInput;
            }
        }
    }
}

test "flipping one byte never reproduces the original" {
    try provider.load();
    const raw = try std.testing.allocator.alloc(u8, q8_payload_bytes);
    defer std.testing.allocator.free(raw);
    const original = fx.qualityPayload(fx.source.q8, raw);

    const damaged = try std.testing.allocator.alloc(
        u8,
        @max(fx.r4x16.q8_0.len, fx.arith.q8_0.len),
    );
    defer std.testing.allocator.free(damaged);
    const plain = try std.testing.allocator.alloc(u8, original.len);
    defer std.testing.allocator.free(plain);

    const cases = [_]struct { decoder: Decoder, stream: []const u8 }{
        .{ .decoder = .rans4x16, .stream = fx.r4x16.q8_0 },
        .{ .decoder = .arith, .stream = fx.arith.q8_0 },
    };

    for (cases) |case| {
        // Deterministic damage points: the first and last bytes (framing),
        // the middle (payload), and a few interior bytes.
        const sites = [_]usize{
            0,
            1,
            2,
            case.stream.len / 4,
            case.stream.len / 2,
            (3 * case.stream.len) / 4,
            case.stream.len - 3,
            case.stream.len - 2,
            case.stream.len - 1,
        };
        for (sites) |at| {
            if (at >= case.stream.len) continue;
            @memcpy(damaged[0..case.stream.len], case.stream);
            damaged[at] ^= 0x5a;

            if (case.decoder.decode(damaged[0..case.stream.len], plain)) |n| {
                if (std.mem.eql(u8, plain[0..n], original)) {
                    std.debug.print(
                        "flipping byte {d} of a {d}-byte stream still decoded to the original\n",
                        .{ at, case.stream.len },
                    );
                    return error.CorruptionReproducedInput;
                }
            } else |err| {
                try std.testing.expectEqual(Error.OperationFailed, err);
            }
        }
    }
}

test "an undersized destination is reported, not overrun" {
    try provider.load();
    const raw = try std.testing.allocator.alloc(u8, q8_payload_bytes);
    defer std.testing.allocator.free(raw);
    const original = fx.qualityPayload(fx.source.q8, raw);

    // One byte short of what the stream needs, followed by a sentinel so an
    // overrun would be visible rather than silent.
    const short_len = original.len - 1;
    const with_sentinel = try std.testing.allocator.alloc(u8, original.len);
    defer std.testing.allocator.free(with_sentinel);
    with_sentinel[short_len] = 0xa5;

    for ([_]Decoder{ .rans4x16, .arith }) |decoder| {
        const stream = if (decoder == .rans4x16) fx.r4x16.q8_0 else fx.arith.q8_0;
        try std.testing.expectError(
            Error.OperationFailed,
            decoder.decode(stream, with_sentinel[0..short_len]),
        );
        try std.testing.expectEqual(@as(u8, 0xa5), with_sentinel[short_len]);
    }
}

test "a zero-length destination is rejected before the codec runs" {
    try provider.load();
    var none: [0]u8 = .{};
    try std.testing.expectError(
        Error.BufferTooSmall,
        htscodecs.rans4x16.uncompressTo(fx.r4x16.q8_0, &none),
    );
    try std.testing.expectError(
        Error.BufferTooSmall,
        htscodecs.arith.uncompressTo(fx.arith.q8_0, &none),
    );
    try std.testing.expectError(
        Error.BufferTooSmall,
        htscodecs.rans4x16.compressTo("payload", &none, 0),
    );
    try std.testing.expectError(
        Error.BufferTooSmall,
        htscodecs.arith.compressTo("payload", &none, 0),
    );
}

test "a damaged fqzcomp stream never reproduces the original" {
    try provider.load();
    const raw = try std.testing.allocator.alloc(u8, q8_payload_bytes);
    defer std.testing.allocator.free(raw);
    // A decoded fqzcomp block holds raw phred scores: upstream's driver
    // subtracts the ASCII offset on the way in
    // (`tests/fqzcomp_qual_test.c:313`) and adds it back only when it
    // prints (`:413`).  Comparing against the ASCII form would make this
    // check unfalsifiable, since a decoded block can never equal one.
    const original = fx.qualityPayload(fx.source.q8, raw);
    for (original) |*byte| byte.* -= 33;
    const stream = fx.fqzcomp.q8_0;

    for ([_]usize{ 1, 2, 3 }) |part| {
        const cut = stream.len * part / 4;
        if (cut == 0) continue;
        if (htscodecs.fqzcomp.decompress(stream[0..cut])) |owned| {
            defer owned.deinit();
            if (std.mem.eql(u8, owned.slice(), original)) {
                return error.TruncationReproducedInput;
            }
        } else |err| {
            try std.testing.expectEqual(Error.OperationFailed, err);
        }
    }
}

test "a damaged tokenised name block never reproduces the original" {
    try provider.load();
    const original = fx.source.set_01_names;
    const stream = fx.tok3.set_01_names_5;

    for ([_]usize{ 1, 2, 3 }) |part| {
        const cut = stream.len * part / 4;
        if (cut == 0) continue;
        if (htscodecs.tok3.decodeNames(stream[0..cut])) |owned| {
            defer owned.deinit();
            if (owned.len != original.len) continue;
            const rebuilt = try fx.splitNames(std.testing.allocator, owned.slice());
            defer std.testing.allocator.free(rebuilt);
            if (std.mem.eql(u8, rebuilt, original)) {
                return error.TruncationReproducedInput;
            }
        } else |err| {
            try std.testing.expectEqual(Error.OperationFailed, err);
        }
    }
}
