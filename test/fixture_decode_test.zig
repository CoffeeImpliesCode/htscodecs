//! Independent decode oracles built from upstream's own fixture data.
//!
//! Upstream ships the *compressed* form of every corpus file next to the
//! plain input, generated once at release time by its own encoders.  That
//! makes the plain file an oracle this fork did not produce: if decoding a
//! checked-in stream does not reproduce the checked-in source byte for
//! byte, something is wrong with the library, the feature macros or the
//! fixture selection.
//!
//! Provenance: every byte under `tests/dat` and `tests/names` comes from
//! samtools/htscodecs at tag v1.6.7.  See fixtures.zig for the mapping.

const std = @import("std");
const htscodecs = @import("htscodecs");
const fx = @import("fixtures");

/// Large enough to hold the column-stripped form of any quality corpus.
/// `qualityPayload` never grows its output: every byte it writes came from
/// the input, so the input's length is the bound.
const corpus_max: usize = @max(
    @max(fx.source.q4.len, fx.source.q8.len),
    @max(fx.source.q40_dir.len, fx.source.qvar.len),
);

fn expectRans4x8(compressed: []const u8, want: []const u8) !void {
    const got = try htscodecs.rans4x8.uncompress(compressed);
    defer got.deinit();
    try std.testing.expectEqualSlices(u8, want, got.slice());
}

/// Decodes through the owned path and then again through the caller-buffer
/// path.  Sizing the destination from the oracle is legitimate here: the
/// 4x16 decoder reads the original length out of the stream and only needs
/// a buffer at least that large, so an exact-size destination also proves
/// that the reported length is the real one.
fn expectRans4x16(compressed: []const u8, want: []const u8) !void {
    const owned = try htscodecs.rans4x16.uncompress(compressed);
    defer owned.deinit();
    try std.testing.expectEqualSlices(u8, want, owned.slice());

    const buf = try std.testing.allocator.alloc(u8, want.len);
    defer std.testing.allocator.free(buf);
    const n = try htscodecs.rans4x16.uncompressTo(compressed, buf);
    try std.testing.expectEqual(want.len, n);
    try std.testing.expectEqualSlices(u8, want, buf);
}

fn expectArith(compressed: []const u8, want: []const u8) !void {
    const owned = try htscodecs.arith.uncompress(compressed);
    defer owned.deinit();
    try std.testing.expectEqualSlices(u8, want, owned.slice());

    const buf = try std.testing.allocator.alloc(u8, want.len);
    defer std.testing.allocator.free(buf);
    const n = try htscodecs.arith.uncompressTo(compressed, buf);
    try std.testing.expectEqual(want.len, n);
    try std.testing.expectEqualSlices(u8, want, buf);
}

/// Decodes a fqzcomp fixture and rebuilds the ASCII record stream from the
/// per-record lengths the decoder reports.  Scores come back as raw phred
/// values, so `fixtures.qualityRecords` shifts them back the 33 upstream's
/// own test driver adds (`fqzcomp_qual_test.c:413`) and terminates each
/// record the way its `puts` does.
///
/// `lengths` must have room for every record the block holds: upstream
/// writes one entry per record it decodes and drops the rest if the array
/// is short (`fqzcomp_qual.c:1419`), so a buffer sized below the record
/// count loses lengths rather than reporting an error.
fn expectFqzcomp(compressed: []const u8, want: []const u8) !void {
    const records = fx.recordCount(want);
    const lengths = try std.testing.allocator.alloc(c_int, records);
    defer std.testing.allocator.free(lengths);

    const got = try htscodecs.fqzcomp.decompressLengths(compressed, lengths);
    defer got.deinit();

    const rebuilt = try fx.qualityRecords(std.testing.allocator, got.slice(), lengths);
    defer std.testing.allocator.free(rebuilt);
    try std.testing.expectEqualSlices(u8, want, rebuilt);
}

/// Decodes a tokenised read-name fixture and turns the NUL separators back
/// into newlines, exactly as upstream's `tr '\000' '\012'` does.
fn expectTok3(compressed: []const u8, want: []const u8) !void {
    const got = try htscodecs.tok3.decodeNames(compressed);
    defer got.deinit();
    try std.testing.expectEqual(want.len, got.len);

    const rebuilt = try fx.splitNames(std.testing.allocator, got.slice());
    defer std.testing.allocator.free(rebuilt);
    try std.testing.expectEqualSlices(u8, want, rebuilt);
}

// ---------------------------------------------------------------------------
// rANS 4x8
// ---------------------------------------------------------------------------

test "rANS 4x8 decodes every upstream order-0 and order-1 fixture" {
    const raw = try std.testing.allocator.alloc(u8, corpus_max);
    defer std.testing.allocator.free(raw);

    inline for (.{
        .{ fx.source.q4, fx.r4x8.q4_0 },
        .{ fx.source.q4, fx.r4x8.q4_1 },
        .{ fx.source.q8, fx.r4x8.q8_0 },
        .{ fx.source.q8, fx.r4x8.q8_1 },
        .{ fx.source.qvar, fx.r4x8.qvar_0 },
        .{ fx.source.qvar, fx.r4x8.qvar_1 },
        .{ fx.source.q40_dir, fx.r4x8.q40_dir_0 },
        .{ fx.source.q40_dir, fx.r4x8.q40_dir_1 },
    }) |pair| {
        try expectRans4x8(pair[1], fx.qualityPayload(pair[0], raw));
    }
}

// ---------------------------------------------------------------------------
// rANS 4x16
// ---------------------------------------------------------------------------

test "rANS 4x16 decodes every upstream fixture, including X32, RLE, PACK and STRIPE orders" {
    const raw = try std.testing.allocator.alloc(u8, corpus_max);
    defer std.testing.allocator.free(raw);

    // Order bytes used by the fixtures: 4 = X32, 5 = X32 | order-1,
    // 8 = STRIPE, 9 = STRIPE | order-1, 32 = STRIPE with N = 1,
    // 64 = RLE, 65 = RLE | order-1, 69 = RLE | X32 | order-1,
    // 128 = PACK, 129 = PACK | order-1, 192 = RLE | PACK,
    // 193 = RLE | PACK | order-1.
    // Exactly the files in tests/dat/r4x16, one entry each.  A name that
    // is not in that directory is a fixture that does not exist, so this
    // list mirrors the directory rather than guessing at order-byte
    // combinations: upstream ships no q8.8 or q8.9 for the 4x16 coder.
    inline for (.{
        .{ fx.source.q4, fx.r4x16.q4_0 },
        .{ fx.source.q4, fx.r4x16.q4_1 },
        .{ fx.source.q4, fx.r4x16.q4_4 },
        .{ fx.source.q4, fx.r4x16.q4_5 },
        .{ fx.source.q4, fx.r4x16.q4_8 },
        .{ fx.source.q4, fx.r4x16.q4_9 },
        .{ fx.source.q4, fx.r4x16.q4_64 },
        .{ fx.source.q4, fx.r4x16.q4_65 },
        .{ fx.source.q4, fx.r4x16.q4_128 },
        .{ fx.source.q4, fx.r4x16.q4_129 },
        .{ fx.source.q4, fx.r4x16.q4_192 },
        .{ fx.source.q4, fx.r4x16.q4_193 },
        .{ fx.source.q8, fx.r4x16.q8_0 },
        .{ fx.source.q8, fx.r4x16.q8_1 },
        .{ fx.source.q8, fx.r4x16.q8_4 },
        .{ fx.source.q8, fx.r4x16.q8_5 },
        .{ fx.source.q8, fx.r4x16.q8_64 },
        .{ fx.source.q8, fx.r4x16.q8_65 },
        .{ fx.source.q8, fx.r4x16.q8_128 },
        .{ fx.source.q8, fx.r4x16.q8_129 },
        .{ fx.source.q8, fx.r4x16.q8_192 },
        .{ fx.source.q8, fx.r4x16.q8_193 },
        .{ fx.source.qvar, fx.r4x16.qvar_0 },
        .{ fx.source.qvar, fx.r4x16.qvar_1 },
        .{ fx.source.qvar, fx.r4x16.qvar_4 },
        .{ fx.source.qvar, fx.r4x16.qvar_5 },
        .{ fx.source.qvar, fx.r4x16.qvar_32 },
        .{ fx.source.q40_dir, fx.r4x16.q40_dir_0 },
        .{ fx.source.q40_dir, fx.r4x16.q40_dir_1 },
        .{ fx.source.q40_dir, fx.r4x16.q40_dir_4 },
        .{ fx.source.q40_dir, fx.r4x16.q40_dir_5 },
        .{ fx.source.q40_dir, fx.r4x16.q40_dir_8 },
        .{ fx.source.q40_dir, fx.r4x16.q40_dir_9 },
    }) |pair| {
        try expectRans4x16(pair[1], fx.qualityPayload(pair[0], raw));
    }
}

test "rANS 4x16 decodes the SIMD stress fixture" {
    // qsimd has neither tabs nor newlines, so the whole file is the payload,
    // which is what upstream's cut/tr pipeline yields for it too.
    const raw = try std.testing.allocator.alloc(u8, fx.source.qsimd.len);
    defer std.testing.allocator.free(raw);
    try expectRans4x16(fx.r4x16.qsimd_69, fx.qualityPayload(fx.source.qsimd, raw));
}

// ---------------------------------------------------------------------------
// Dynamic arithmetic coder
// ---------------------------------------------------------------------------

test "the arithmetic coder decodes every upstream quality fixture" {
    const raw = try std.testing.allocator.alloc(u8, corpus_max);
    defer std.testing.allocator.free(raw);

    // Exactly the files in tests/dat/arith, one entry each, for the same
    // reason as above.
    inline for (.{
        .{ fx.source.q4, fx.arith.q4_0 },
        .{ fx.source.q4, fx.arith.q4_1 },
        .{ fx.source.q4, fx.arith.q4_8 },
        .{ fx.source.q4, fx.arith.q4_9 },
        .{ fx.source.q4, fx.arith.q4_64 },
        .{ fx.source.q4, fx.arith.q4_65 },
        .{ fx.source.q4, fx.arith.q4_128 },
        .{ fx.source.q4, fx.arith.q4_129 },
        .{ fx.source.q4, fx.arith.q4_192 },
        .{ fx.source.q4, fx.arith.q4_193 },
        .{ fx.source.q8, fx.arith.q8_0 },
        .{ fx.source.q8, fx.arith.q8_1 },
        .{ fx.source.q8, fx.arith.q8_64 },
        .{ fx.source.q8, fx.arith.q8_65 },
        .{ fx.source.q8, fx.arith.q8_128 },
        .{ fx.source.q8, fx.arith.q8_129 },
        .{ fx.source.q8, fx.arith.q8_192 },
        .{ fx.source.q8, fx.arith.q8_193 },
        .{ fx.source.qvar, fx.arith.qvar_0 },
        .{ fx.source.qvar, fx.arith.qvar_1 },
        .{ fx.source.qvar, fx.arith.qvar_32 },
        .{ fx.source.qvar, fx.arith.qvar_64 },
        .{ fx.source.qvar, fx.arith.qvar_65 },
        .{ fx.source.q40_dir, fx.arith.q40_dir_0 },
        .{ fx.source.q40_dir, fx.arith.q40_dir_1 },
        .{ fx.source.q40_dir, fx.arith.q40_dir_8 },
        .{ fx.source.q40_dir, fx.arith.q40_dir_9 },
        .{ fx.source.q40_dir, fx.arith.q40_dir_64 },
        .{ fx.source.q40_dir, fx.arith.q40_dir_65 },
    }) |pair| {
        try expectArith(pair[1], fx.qualityPayload(pair[0], raw));
    }
}

test "the arithmetic coder decodes the whole-file u32 fixtures" {
    // arith.test feeds the u32 corpus to the encoder with `cp`, not with
    // cut, so the oracle is the file itself.
    inline for (.{
        fx.arith.u32_1,
        fx.arith.u32_9,
        fx.arith.u32_65,
    }) |compressed| {
        try expectArith(compressed, fx.source.u32_dat);
    }
}

test "the bzip2-backed arithmetic fixture is only decodable with -Dbz2=true" {
    // tests/dat/arith/u32.4 has order byte 0x04, which is X_EXT: the block
    // was handed to libbz2 when the fixture was made.  The default build
    // compiles that method out, so decoding must fail rather than quietly
    // return plausible bytes.  This is the documented cost of the opt-in.
    if (htscodecs.arith.uncompress(fx.arith.u32_4)) |owned| {
        defer owned.deinit();
        try std.testing.expectEqualSlices(u8, fx.source.u32_dat, owned.slice());
    } else |err| {
        try std.testing.expectEqual(htscodecs.Error.OperationFailed, err);
    }
}

// ---------------------------------------------------------------------------
// fqzcomp quality scores
// ---------------------------------------------------------------------------

test "fqzcomp decodes every upstream fixture at all four strategies" {
    inline for (.{
        .{ fx.source.q4, fx.fqzcomp.q4_0 },
        .{ fx.source.q4, fx.fqzcomp.q4_1 },
        .{ fx.source.q4, fx.fqzcomp.q4_2 },
        .{ fx.source.q4, fx.fqzcomp.q4_3 },
        .{ fx.source.q8, fx.fqzcomp.q8_0 },
        .{ fx.source.q8, fx.fqzcomp.q8_1 },
        .{ fx.source.q8, fx.fqzcomp.q8_2 },
        .{ fx.source.q8, fx.fqzcomp.q8_3 },
        .{ fx.source.qvar, fx.fqzcomp.qvar_0 },
        .{ fx.source.qvar, fx.fqzcomp.qvar_1 },
        .{ fx.source.qvar, fx.fqzcomp.qvar_2 },
        .{ fx.source.qvar, fx.fqzcomp.qvar_3 },
        .{ fx.source.q40_dir, fx.fqzcomp.q40_dir_0 },
        .{ fx.source.q40_dir, fx.fqzcomp.q40_dir_1 },
        .{ fx.source.q40_dir, fx.fqzcomp.q40_dir_2 },
        .{ fx.source.q40_dir, fx.fqzcomp.q40_dir_3 },
    }) |pair| {
        // Scoped so the buffer is released per fixture rather than at the
        // end of the test, which would hold every corpus at once.
        {
            const want = try fx.qualityLines(std.testing.allocator, pair[0]);
            defer std.testing.allocator.free(want);
            try expectFqzcomp(pair[1], want);
        }
    }
}

// ---------------------------------------------------------------------------
// Read-name tokeniser
// ---------------------------------------------------------------------------

test "the tokeniser decodes every upstream fixture at every level" {
    // One entry per file in tests/names/tok3: eleven name blocks at the
    // ten levels upstream ships (1, 3, 5, 7, 9 and the arithmetic-coder
    // levels 11 to 19).  A sample of them would leave most of the
    // directory unexercised, and the directory is what this fork embeds.
    inline for (.{
        .{ fx.source.set_01_names, fx.tok3.set_01_names_1 },
        .{ fx.source.set_01_names, fx.tok3.set_01_names_3 },
        .{ fx.source.set_01_names, fx.tok3.set_01_names_5 },
        .{ fx.source.set_01_names, fx.tok3.set_01_names_7 },
        .{ fx.source.set_01_names, fx.tok3.set_01_names_9 },
        .{ fx.source.set_01_names, fx.tok3.set_01_names_11 },
        .{ fx.source.set_01_names, fx.tok3.set_01_names_13 },
        .{ fx.source.set_01_names, fx.tok3.set_01_names_15 },
        .{ fx.source.set_01_names, fx.tok3.set_01_names_17 },
        .{ fx.source.set_01_names, fx.tok3.set_01_names_19 },
        .{ fx.source.set_02_names, fx.tok3.set_02_names_1 },
        .{ fx.source.set_02_names, fx.tok3.set_02_names_3 },
        .{ fx.source.set_02_names, fx.tok3.set_02_names_5 },
        .{ fx.source.set_02_names, fx.tok3.set_02_names_7 },
        .{ fx.source.set_02_names, fx.tok3.set_02_names_9 },
        .{ fx.source.set_02_names, fx.tok3.set_02_names_11 },
        .{ fx.source.set_02_names, fx.tok3.set_02_names_13 },
        .{ fx.source.set_02_names, fx.tok3.set_02_names_15 },
        .{ fx.source.set_02_names, fx.tok3.set_02_names_17 },
        .{ fx.source.set_02_names, fx.tok3.set_02_names_19 },
        .{ fx.source.set_03_names, fx.tok3.set_03_names_1 },
        .{ fx.source.set_03_names, fx.tok3.set_03_names_3 },
        .{ fx.source.set_03_names, fx.tok3.set_03_names_5 },
        .{ fx.source.set_03_names, fx.tok3.set_03_names_7 },
        .{ fx.source.set_03_names, fx.tok3.set_03_names_9 },
        .{ fx.source.set_03_names, fx.tok3.set_03_names_11 },
        .{ fx.source.set_03_names, fx.tok3.set_03_names_13 },
        .{ fx.source.set_03_names, fx.tok3.set_03_names_15 },
        .{ fx.source.set_03_names, fx.tok3.set_03_names_17 },
        .{ fx.source.set_03_names, fx.tok3.set_03_names_19 },
        .{ fx.source.set_05_names, fx.tok3.set_05_names_1 },
        .{ fx.source.set_05_names, fx.tok3.set_05_names_3 },
        .{ fx.source.set_05_names, fx.tok3.set_05_names_5 },
        .{ fx.source.set_05_names, fx.tok3.set_05_names_7 },
        .{ fx.source.set_05_names, fx.tok3.set_05_names_9 },
        .{ fx.source.set_05_names, fx.tok3.set_05_names_11 },
        .{ fx.source.set_05_names, fx.tok3.set_05_names_13 },
        .{ fx.source.set_05_names, fx.tok3.set_05_names_15 },
        .{ fx.source.set_05_names, fx.tok3.set_05_names_17 },
        .{ fx.source.set_05_names, fx.tok3.set_05_names_19 },
        .{ fx.source.set_08_names, fx.tok3.set_08_names_1 },
        .{ fx.source.set_08_names, fx.tok3.set_08_names_3 },
        .{ fx.source.set_08_names, fx.tok3.set_08_names_5 },
        .{ fx.source.set_08_names, fx.tok3.set_08_names_7 },
        .{ fx.source.set_08_names, fx.tok3.set_08_names_9 },
        .{ fx.source.set_08_names, fx.tok3.set_08_names_11 },
        .{ fx.source.set_08_names, fx.tok3.set_08_names_13 },
        .{ fx.source.set_08_names, fx.tok3.set_08_names_15 },
        .{ fx.source.set_08_names, fx.tok3.set_08_names_17 },
        .{ fx.source.set_08_names, fx.tok3.set_08_names_19 },
        .{ fx.source.set_09_names, fx.tok3.set_09_names_1 },
        .{ fx.source.set_09_names, fx.tok3.set_09_names_3 },
        .{ fx.source.set_09_names, fx.tok3.set_09_names_5 },
        .{ fx.source.set_09_names, fx.tok3.set_09_names_7 },
        .{ fx.source.set_09_names, fx.tok3.set_09_names_9 },
        .{ fx.source.set_09_names, fx.tok3.set_09_names_11 },
        .{ fx.source.set_09_names, fx.tok3.set_09_names_13 },
        .{ fx.source.set_09_names, fx.tok3.set_09_names_15 },
        .{ fx.source.set_09_names, fx.tok3.set_09_names_17 },
        .{ fx.source.set_09_names, fx.tok3.set_09_names_19 },
        .{ fx.source.set_10_names, fx.tok3.set_10_names_1 },
        .{ fx.source.set_10_names, fx.tok3.set_10_names_3 },
        .{ fx.source.set_10_names, fx.tok3.set_10_names_5 },
        .{ fx.source.set_10_names, fx.tok3.set_10_names_7 },
        .{ fx.source.set_10_names, fx.tok3.set_10_names_9 },
        .{ fx.source.set_10_names, fx.tok3.set_10_names_11 },
        .{ fx.source.set_10_names, fx.tok3.set_10_names_13 },
        .{ fx.source.set_10_names, fx.tok3.set_10_names_15 },
        .{ fx.source.set_10_names, fx.tok3.set_10_names_17 },
        .{ fx.source.set_10_names, fx.tok3.set_10_names_19 },
        .{ fx.source.set_20_names, fx.tok3.set_20_names_1 },
        .{ fx.source.set_20_names, fx.tok3.set_20_names_3 },
        .{ fx.source.set_20_names, fx.tok3.set_20_names_5 },
        .{ fx.source.set_20_names, fx.tok3.set_20_names_7 },
        .{ fx.source.set_20_names, fx.tok3.set_20_names_9 },
        .{ fx.source.set_20_names, fx.tok3.set_20_names_11 },
        .{ fx.source.set_20_names, fx.tok3.set_20_names_13 },
        .{ fx.source.set_20_names, fx.tok3.set_20_names_15 },
        .{ fx.source.set_20_names, fx.tok3.set_20_names_17 },
        .{ fx.source.set_20_names, fx.tok3.set_20_names_19 },
        .{ fx.source.nv_names, fx.tok3.nv_names_1 },
        .{ fx.source.nv_names, fx.tok3.nv_names_3 },
        .{ fx.source.nv_names, fx.tok3.nv_names_5 },
        .{ fx.source.nv_names, fx.tok3.nv_names_7 },
        .{ fx.source.nv_names, fx.tok3.nv_names_9 },
        .{ fx.source.nv_names, fx.tok3.nv_names_11 },
        .{ fx.source.nv_names, fx.tok3.nv_names_13 },
        .{ fx.source.nv_names, fx.tok3.nv_names_15 },
        .{ fx.source.nv_names, fx.tok3.nv_names_17 },
        .{ fx.source.nv_names, fx.tok3.nv_names_19 },
        .{ fx.source.nv2_names, fx.tok3.nv2_names_1 },
        .{ fx.source.nv2_names, fx.tok3.nv2_names_3 },
        .{ fx.source.nv2_names, fx.tok3.nv2_names_5 },
        .{ fx.source.nv2_names, fx.tok3.nv2_names_7 },
        .{ fx.source.nv2_names, fx.tok3.nv2_names_9 },
        .{ fx.source.nv2_names, fx.tok3.nv2_names_11 },
        .{ fx.source.nv2_names, fx.tok3.nv2_names_13 },
        .{ fx.source.nv2_names, fx.tok3.nv2_names_15 },
        .{ fx.source.nv2_names, fx.tok3.nv2_names_17 },
        .{ fx.source.nv2_names, fx.tok3.nv2_names_19 },
        .{ fx.source.rr_names, fx.tok3.rr_names_1 },
        .{ fx.source.rr_names, fx.tok3.rr_names_3 },
        .{ fx.source.rr_names, fx.tok3.rr_names_5 },
        .{ fx.source.rr_names, fx.tok3.rr_names_7 },
        .{ fx.source.rr_names, fx.tok3.rr_names_9 },
        .{ fx.source.rr_names, fx.tok3.rr_names_11 },
        .{ fx.source.rr_names, fx.tok3.rr_names_13 },
        .{ fx.source.rr_names, fx.tok3.rr_names_15 },
        .{ fx.source.rr_names, fx.tok3.rr_names_17 },
        .{ fx.source.rr_names, fx.tok3.rr_names_19 },
    }) |pair| {
        try expectTok3(pair[1], pair[0]);
    }
}
