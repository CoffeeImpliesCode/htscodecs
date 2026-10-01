//! Upstream test data, embedded so the tests and the example are hermetic.
//!
//! Every byte here comes from the samtools/htscodecs repository at tag
//! v1.6.7, paths `tests/dat` and `tests/names`.  Upstream generates them
//! with its own release-time encoders and then checks them in, which makes
//! them independent oracles: the expected output of decoding a fixture is
//! the plain source data, not something this fork produced.
//!
//! Provenance for each group:
//!   tests/dat/q4, q8, qvar, q40+dir, u32, qsimd
//!       plain inputs.  The `q*` files are tab-separated; column 1 is the
//!       quality string and the remaining columns are per-record flags.
//!       `u32` is raw little-endian 32-bit words and `qsimd` is a SIMD
//!       stress pattern with no newlines.
//!   tests/dat/r4x8, r4x16, arith, fqzcomp
//!       compressed forms of the above, one file per (input, order) or
//!       (input, strategy) pair.
//!   tests/names/*.names
//!       plain read-name blocks.
//!   tests/names/tok3/*.names.<level>
//!       tokenised forms at levels 1, 3, 5, ... 19.
//!
//! This module is not part of the public package surface; only the tests
//! and the example import it.
//!
//! SPDX-License-Identifier: BSD-3-Clause

const std = @import("std");

/// Reproduces `cut -f 1 < file | tr -d '\012'`, which is how upstream's
/// shell tests derive the uncompressed side of every quality fixture.
///
/// For a tab-separated file that is column 1 of each line with the line
/// terminators removed.  For a file with no tabs and no newlines (`qsimd`)
/// it is the file itself, which is what upstream's pipeline produces too.
///
/// `out` must be at least `raw.len` bytes; the result is a prefix of it.
/// The assert below is a debug-only net for that precondition, not a guard:
/// it vanishes in ReleaseFast and ReleaseSmall, so the size is the caller's
/// responsibility, and every call site in this repository allocates `out`
/// from the length of the input it passes.
pub fn qualityPayload(raw: []const u8, out: []u8) []u8 {
    std.debug.assert(out.len >= raw.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        switch (raw[i]) {
            '\n' => {},
            '\t' => while (i < raw.len and raw[i] != '\n') : (i += 1) {},
            else => {
                out[n] = raw[i];
                n += 1;
            },
        }
    }
    return out[0..n];
}

/// `cut -f 1` of a quality corpus: column 1 of every line, newline
/// terminated.
///
/// That is the block `tests/fqzcomp.test:11` hands to the fqzcomp encoder,
/// and therefore the oracle a decoded fqzcomp stream has to reproduce.
/// Every line contributes a terminator whether or not the source had one
/// there, so the result is not always the length of its input; it is
/// allocated for that reason.
pub fn qualityLines(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        while (i < raw.len and raw[i] != '\n' and raw[i] != '\t') : (i += 1) {
            try out.append(allocator, raw[i]);
        }
        try out.append(allocator, '\n');
        // Consume the rest of the source line with its terminator, so a
        // record without one cannot spin here.
        while (i < raw.len and raw[i] != '\n') : (i += 1) {}
        if (i < raw.len) i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// The ASCII record stream a decoded fqzcomp block stands for.
///
/// `tests/fqzcomp_qual_test.c:409-417` walks the record lengths the decoder
/// reports and prints each record as `out[j+k] + 33` followed by a newline,
/// which is byte for byte what `qualityLines` produces for the corpus the
/// stream was built from.  `qualities` is the raw phred block: upstream
/// subtracts the same 33 on the way in (`fqzcomp_qual_test.c:313`).
///
/// `lengths` must be the decoder's own record lengths and must sum to
/// `qualities.len`.  A disagreement means the block and the lengths came
/// from different streams, and the alternative - returning a short buffer -
/// would compare equal to nothing.
pub fn qualityRecords(
    allocator: std.mem.Allocator,
    qualities: []const u8,
    lengths: []const c_int,
) ![]u8 {
    var total: usize = 0;
    for (lengths) |len| {
        if (len <= 0) return error.RecordLengthOutOfRange;
        total += @intCast(len);
    }
    if (total != qualities.len) return error.RecordLengthOutOfRange;

    const out = try allocator.alloc(u8, total + lengths.len);
    errdefer allocator.free(out);

    // Two offsets, because the two streams grow differently: the phred
    // block carries no separators and the ASCII form gains one per record.
    var src: usize = 0;
    var dst: usize = 0;
    for (lengths) |len| {
        const n: usize = @intCast(len);
        for (qualities[src..][0..n], 0..) |score, k| out[dst + k] = score + 33;
        src += n;
        dst += n;
        out[dst] = '\n';
        dst += 1;
    }
    return out;
}

/// Number of records in a `qualityLines` block, which is how many entries a
/// decoder has to report a length for.
pub fn recordCount(lines: []const u8) usize {
    var n: usize = 0;
    for (lines) |byte| {
        if (byte == '\n') n += 1;
    }
    return n;
}

/// Splits a quality block into its records.  Each NUL that separates one name
/// from the next becomes a newline, which is what upstream's
/// `tr '\000' '\012'` round trip produces.
///
/// The result is allocated rather than written into a caller buffer: the
/// length is exactly `encoded.len`, so a caller that guessed wrong either
/// truncated silently or tripped an assertion, and this is a test oracle
/// where a silent truncation would compare equal to nothing.
pub fn splitNames(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, encoded.len);
    errdefer allocator.free(out);
    @memcpy(out, encoded);
    for (encoded, 0..) |byte, i| {
        if (byte == 0) out[i] = '\n';
    }
    return out;
}

/// Plain upstream inputs.
pub const source = struct {
    pub const q4 = @embedFile("tests/dat/q4");
    pub const q8 = @embedFile("tests/dat/q8");
    pub const qvar = @embedFile("tests/dat/qvar");
    pub const q40_dir = @embedFile("tests/dat/q40+dir");
    // Not `u32`: a declaration of that name is a primitive shadow and the
    // compiler rejects it, so the upstream file name is carried with a
    // suffix instead.  The `arith` block below keeps `u32_1` and friends,
    // which are ordinary identifiers and need no change.
    pub const u32_dat = @embedFile("tests/dat/u32");
    pub const qsimd = @embedFile("tests/dat/qsimd");
    pub const set_01_names = @embedFile("tests/names/01.names");
    pub const set_02_names = @embedFile("tests/names/02.names");
    pub const set_03_names = @embedFile("tests/names/03.names");
    pub const set_05_names = @embedFile("tests/names/05.names");
    pub const set_08_names = @embedFile("tests/names/08.names");
    pub const set_09_names = @embedFile("tests/names/09.names");
    pub const set_10_names = @embedFile("tests/names/10.names");
    pub const set_20_names = @embedFile("tests/names/20.names");
    pub const nv_names = @embedFile("tests/names/nv.names");
    pub const nv2_names = @embedFile("tests/names/nv2.names");
    pub const rr_names = @embedFile("tests/names/rr.names");
};

/// Pre-compressed upstream fixtures for the r4x8 codec.
pub const r4x8 = struct {
    pub const q4_0 = @embedFile("tests/dat/r4x8/q4.0");
    pub const q40_dir_0 = @embedFile("tests/dat/r4x8/q40+dir.0");
    pub const q40_dir_1 = @embedFile("tests/dat/r4x8/q40+dir.1");
    pub const q4_1 = @embedFile("tests/dat/r4x8/q4.1");
    pub const q8_0 = @embedFile("tests/dat/r4x8/q8.0");
    pub const q8_1 = @embedFile("tests/dat/r4x8/q8.1");
    pub const qvar_0 = @embedFile("tests/dat/r4x8/qvar.0");
    pub const qvar_1 = @embedFile("tests/dat/r4x8/qvar.1");
};

/// Pre-compressed upstream fixtures for the r4x16 codec.
pub const r4x16 = struct {
    pub const q4_0 = @embedFile("tests/dat/r4x16/q4.0");
    pub const q40_dir_0 = @embedFile("tests/dat/r4x16/q40+dir.0");
    pub const q40_dir_1 = @embedFile("tests/dat/r4x16/q40+dir.1");
    pub const q40_dir_4 = @embedFile("tests/dat/r4x16/q40+dir.4");
    pub const q40_dir_5 = @embedFile("tests/dat/r4x16/q40+dir.5");
    pub const q40_dir_8 = @embedFile("tests/dat/r4x16/q40+dir.8");
    pub const q40_dir_9 = @embedFile("tests/dat/r4x16/q40+dir.9");
    pub const q4_1 = @embedFile("tests/dat/r4x16/q4.1");
    pub const q4_128 = @embedFile("tests/dat/r4x16/q4.128");
    pub const q4_129 = @embedFile("tests/dat/r4x16/q4.129");
    pub const q4_192 = @embedFile("tests/dat/r4x16/q4.192");
    pub const q4_193 = @embedFile("tests/dat/r4x16/q4.193");
    pub const q4_4 = @embedFile("tests/dat/r4x16/q4.4");
    pub const q4_5 = @embedFile("tests/dat/r4x16/q4.5");
    pub const q4_64 = @embedFile("tests/dat/r4x16/q4.64");
    pub const q4_65 = @embedFile("tests/dat/r4x16/q4.65");
    pub const q4_8 = @embedFile("tests/dat/r4x16/q4.8");
    pub const q4_9 = @embedFile("tests/dat/r4x16/q4.9");
    pub const q8_0 = @embedFile("tests/dat/r4x16/q8.0");
    pub const q8_1 = @embedFile("tests/dat/r4x16/q8.1");
    pub const q8_128 = @embedFile("tests/dat/r4x16/q8.128");
    pub const q8_129 = @embedFile("tests/dat/r4x16/q8.129");
    pub const q8_192 = @embedFile("tests/dat/r4x16/q8.192");
    pub const q8_193 = @embedFile("tests/dat/r4x16/q8.193");
    pub const q8_4 = @embedFile("tests/dat/r4x16/q8.4");
    pub const q8_5 = @embedFile("tests/dat/r4x16/q8.5");
    pub const q8_64 = @embedFile("tests/dat/r4x16/q8.64");
    pub const q8_65 = @embedFile("tests/dat/r4x16/q8.65");
    pub const qsimd_69 = @embedFile("tests/dat/r4x16/qsimd.69");
    pub const qvar_0 = @embedFile("tests/dat/r4x16/qvar.0");
    pub const qvar_1 = @embedFile("tests/dat/r4x16/qvar.1");
    pub const qvar_32 = @embedFile("tests/dat/r4x16/qvar.32");
    pub const qvar_4 = @embedFile("tests/dat/r4x16/qvar.4");
    pub const qvar_5 = @embedFile("tests/dat/r4x16/qvar.5");
};

/// Pre-compressed upstream fixtures for the arith codec.
pub const arith = struct {
    pub const q4_0 = @embedFile("tests/dat/arith/q4.0");
    pub const q40_dir_0 = @embedFile("tests/dat/arith/q40+dir.0");
    pub const q40_dir_1 = @embedFile("tests/dat/arith/q40+dir.1");
    pub const q40_dir_64 = @embedFile("tests/dat/arith/q40+dir.64");
    pub const q40_dir_65 = @embedFile("tests/dat/arith/q40+dir.65");
    pub const q40_dir_8 = @embedFile("tests/dat/arith/q40+dir.8");
    pub const q40_dir_9 = @embedFile("tests/dat/arith/q40+dir.9");
    pub const q4_1 = @embedFile("tests/dat/arith/q4.1");
    pub const q4_128 = @embedFile("tests/dat/arith/q4.128");
    pub const q4_129 = @embedFile("tests/dat/arith/q4.129");
    pub const q4_192 = @embedFile("tests/dat/arith/q4.192");
    pub const q4_193 = @embedFile("tests/dat/arith/q4.193");
    pub const q4_64 = @embedFile("tests/dat/arith/q4.64");
    pub const q4_65 = @embedFile("tests/dat/arith/q4.65");
    pub const q4_8 = @embedFile("tests/dat/arith/q4.8");
    pub const q4_9 = @embedFile("tests/dat/arith/q4.9");
    pub const q8_0 = @embedFile("tests/dat/arith/q8.0");
    pub const q8_1 = @embedFile("tests/dat/arith/q8.1");
    pub const q8_128 = @embedFile("tests/dat/arith/q8.128");
    pub const q8_129 = @embedFile("tests/dat/arith/q8.129");
    pub const q8_192 = @embedFile("tests/dat/arith/q8.192");
    pub const q8_193 = @embedFile("tests/dat/arith/q8.193");
    pub const q8_64 = @embedFile("tests/dat/arith/q8.64");
    pub const q8_65 = @embedFile("tests/dat/arith/q8.65");
    pub const qvar_0 = @embedFile("tests/dat/arith/qvar.0");
    pub const qvar_1 = @embedFile("tests/dat/arith/qvar.1");
    pub const qvar_32 = @embedFile("tests/dat/arith/qvar.32");
    pub const qvar_64 = @embedFile("tests/dat/arith/qvar.64");
    pub const qvar_65 = @embedFile("tests/dat/arith/qvar.65");
    pub const u32_1 = @embedFile("tests/dat/arith/u32.1");
    pub const u32_4 = @embedFile("tests/dat/arith/u32.4");
    pub const u32_65 = @embedFile("tests/dat/arith/u32.65");
    pub const u32_9 = @embedFile("tests/dat/arith/u32.9");
};

/// Pre-compressed upstream fixtures for the fqzcomp codec.
pub const fqzcomp = struct {
    pub const q4_0 = @embedFile("tests/dat/fqzcomp/q4.0");
    pub const q40_dir_0 = @embedFile("tests/dat/fqzcomp/q40+dir.0");
    pub const q40_dir_1 = @embedFile("tests/dat/fqzcomp/q40+dir.1");
    pub const q40_dir_2 = @embedFile("tests/dat/fqzcomp/q40+dir.2");
    pub const q40_dir_3 = @embedFile("tests/dat/fqzcomp/q40+dir.3");
    pub const q4_1 = @embedFile("tests/dat/fqzcomp/q4.1");
    pub const q4_2 = @embedFile("tests/dat/fqzcomp/q4.2");
    pub const q4_3 = @embedFile("tests/dat/fqzcomp/q4.3");
    pub const q8_0 = @embedFile("tests/dat/fqzcomp/q8.0");
    pub const q8_1 = @embedFile("tests/dat/fqzcomp/q8.1");
    pub const q8_2 = @embedFile("tests/dat/fqzcomp/q8.2");
    pub const q8_3 = @embedFile("tests/dat/fqzcomp/q8.3");
    pub const qvar_0 = @embedFile("tests/dat/fqzcomp/qvar.0");
    pub const qvar_1 = @embedFile("tests/dat/fqzcomp/qvar.1");
    pub const qvar_2 = @embedFile("tests/dat/fqzcomp/qvar.2");
    pub const qvar_3 = @embedFile("tests/dat/fqzcomp/qvar.3");
};

/// Pre-compressed upstream fixtures for the read-name tokeniser.
pub const tok3 = struct {
    pub const set_01_names_1 = @embedFile("tests/names/tok3/01.names.1");
    pub const set_01_names_11 = @embedFile("tests/names/tok3/01.names.11");
    pub const set_01_names_13 = @embedFile("tests/names/tok3/01.names.13");
    pub const set_01_names_15 = @embedFile("tests/names/tok3/01.names.15");
    pub const set_01_names_17 = @embedFile("tests/names/tok3/01.names.17");
    pub const set_01_names_19 = @embedFile("tests/names/tok3/01.names.19");
    pub const set_01_names_3 = @embedFile("tests/names/tok3/01.names.3");
    pub const set_01_names_5 = @embedFile("tests/names/tok3/01.names.5");
    pub const set_01_names_7 = @embedFile("tests/names/tok3/01.names.7");
    pub const set_01_names_9 = @embedFile("tests/names/tok3/01.names.9");
    pub const set_02_names_1 = @embedFile("tests/names/tok3/02.names.1");
    pub const set_02_names_11 = @embedFile("tests/names/tok3/02.names.11");
    pub const set_02_names_13 = @embedFile("tests/names/tok3/02.names.13");
    pub const set_02_names_15 = @embedFile("tests/names/tok3/02.names.15");
    pub const set_02_names_17 = @embedFile("tests/names/tok3/02.names.17");
    pub const set_02_names_19 = @embedFile("tests/names/tok3/02.names.19");
    pub const set_02_names_3 = @embedFile("tests/names/tok3/02.names.3");
    pub const set_02_names_5 = @embedFile("tests/names/tok3/02.names.5");
    pub const set_02_names_7 = @embedFile("tests/names/tok3/02.names.7");
    pub const set_02_names_9 = @embedFile("tests/names/tok3/02.names.9");
    pub const set_03_names_1 = @embedFile("tests/names/tok3/03.names.1");
    pub const set_03_names_11 = @embedFile("tests/names/tok3/03.names.11");
    pub const set_03_names_13 = @embedFile("tests/names/tok3/03.names.13");
    pub const set_03_names_15 = @embedFile("tests/names/tok3/03.names.15");
    pub const set_03_names_17 = @embedFile("tests/names/tok3/03.names.17");
    pub const set_03_names_19 = @embedFile("tests/names/tok3/03.names.19");
    pub const set_03_names_3 = @embedFile("tests/names/tok3/03.names.3");
    pub const set_03_names_5 = @embedFile("tests/names/tok3/03.names.5");
    pub const set_03_names_7 = @embedFile("tests/names/tok3/03.names.7");
    pub const set_03_names_9 = @embedFile("tests/names/tok3/03.names.9");
    pub const set_05_names_1 = @embedFile("tests/names/tok3/05.names.1");
    pub const set_05_names_11 = @embedFile("tests/names/tok3/05.names.11");
    pub const set_05_names_13 = @embedFile("tests/names/tok3/05.names.13");
    pub const set_05_names_15 = @embedFile("tests/names/tok3/05.names.15");
    pub const set_05_names_17 = @embedFile("tests/names/tok3/05.names.17");
    pub const set_05_names_19 = @embedFile("tests/names/tok3/05.names.19");
    pub const set_05_names_3 = @embedFile("tests/names/tok3/05.names.3");
    pub const set_05_names_5 = @embedFile("tests/names/tok3/05.names.5");
    pub const set_05_names_7 = @embedFile("tests/names/tok3/05.names.7");
    pub const set_05_names_9 = @embedFile("tests/names/tok3/05.names.9");
    pub const set_08_names_1 = @embedFile("tests/names/tok3/08.names.1");
    pub const set_08_names_11 = @embedFile("tests/names/tok3/08.names.11");
    pub const set_08_names_13 = @embedFile("tests/names/tok3/08.names.13");
    pub const set_08_names_15 = @embedFile("tests/names/tok3/08.names.15");
    pub const set_08_names_17 = @embedFile("tests/names/tok3/08.names.17");
    pub const set_08_names_19 = @embedFile("tests/names/tok3/08.names.19");
    pub const set_08_names_3 = @embedFile("tests/names/tok3/08.names.3");
    pub const set_08_names_5 = @embedFile("tests/names/tok3/08.names.5");
    pub const set_08_names_7 = @embedFile("tests/names/tok3/08.names.7");
    pub const set_08_names_9 = @embedFile("tests/names/tok3/08.names.9");
    pub const set_09_names_1 = @embedFile("tests/names/tok3/09.names.1");
    pub const set_09_names_11 = @embedFile("tests/names/tok3/09.names.11");
    pub const set_09_names_13 = @embedFile("tests/names/tok3/09.names.13");
    pub const set_09_names_15 = @embedFile("tests/names/tok3/09.names.15");
    pub const set_09_names_17 = @embedFile("tests/names/tok3/09.names.17");
    pub const set_09_names_19 = @embedFile("tests/names/tok3/09.names.19");
    pub const set_09_names_3 = @embedFile("tests/names/tok3/09.names.3");
    pub const set_09_names_5 = @embedFile("tests/names/tok3/09.names.5");
    pub const set_09_names_7 = @embedFile("tests/names/tok3/09.names.7");
    pub const set_09_names_9 = @embedFile("tests/names/tok3/09.names.9");
    pub const set_10_names_1 = @embedFile("tests/names/tok3/10.names.1");
    pub const set_10_names_11 = @embedFile("tests/names/tok3/10.names.11");
    pub const set_10_names_13 = @embedFile("tests/names/tok3/10.names.13");
    pub const set_10_names_15 = @embedFile("tests/names/tok3/10.names.15");
    pub const set_10_names_17 = @embedFile("tests/names/tok3/10.names.17");
    pub const set_10_names_19 = @embedFile("tests/names/tok3/10.names.19");
    pub const set_10_names_3 = @embedFile("tests/names/tok3/10.names.3");
    pub const set_10_names_5 = @embedFile("tests/names/tok3/10.names.5");
    pub const set_10_names_7 = @embedFile("tests/names/tok3/10.names.7");
    pub const set_10_names_9 = @embedFile("tests/names/tok3/10.names.9");
    pub const set_20_names_1 = @embedFile("tests/names/tok3/20.names.1");
    pub const set_20_names_11 = @embedFile("tests/names/tok3/20.names.11");
    pub const set_20_names_13 = @embedFile("tests/names/tok3/20.names.13");
    pub const set_20_names_15 = @embedFile("tests/names/tok3/20.names.15");
    pub const set_20_names_17 = @embedFile("tests/names/tok3/20.names.17");
    pub const set_20_names_19 = @embedFile("tests/names/tok3/20.names.19");
    pub const set_20_names_3 = @embedFile("tests/names/tok3/20.names.3");
    pub const set_20_names_5 = @embedFile("tests/names/tok3/20.names.5");
    pub const set_20_names_7 = @embedFile("tests/names/tok3/20.names.7");
    pub const set_20_names_9 = @embedFile("tests/names/tok3/20.names.9");
    pub const nv2_names_1 = @embedFile("tests/names/tok3/nv2.names.1");
    pub const nv2_names_11 = @embedFile("tests/names/tok3/nv2.names.11");
    pub const nv2_names_13 = @embedFile("tests/names/tok3/nv2.names.13");
    pub const nv2_names_15 = @embedFile("tests/names/tok3/nv2.names.15");
    pub const nv2_names_17 = @embedFile("tests/names/tok3/nv2.names.17");
    pub const nv2_names_19 = @embedFile("tests/names/tok3/nv2.names.19");
    pub const nv2_names_3 = @embedFile("tests/names/tok3/nv2.names.3");
    pub const nv2_names_5 = @embedFile("tests/names/tok3/nv2.names.5");
    pub const nv2_names_7 = @embedFile("tests/names/tok3/nv2.names.7");
    pub const nv2_names_9 = @embedFile("tests/names/tok3/nv2.names.9");
    pub const nv_names_1 = @embedFile("tests/names/tok3/nv.names.1");
    pub const nv_names_11 = @embedFile("tests/names/tok3/nv.names.11");
    pub const nv_names_13 = @embedFile("tests/names/tok3/nv.names.13");
    pub const nv_names_15 = @embedFile("tests/names/tok3/nv.names.15");
    pub const nv_names_17 = @embedFile("tests/names/tok3/nv.names.17");
    pub const nv_names_19 = @embedFile("tests/names/tok3/nv.names.19");
    pub const nv_names_3 = @embedFile("tests/names/tok3/nv.names.3");
    pub const nv_names_5 = @embedFile("tests/names/tok3/nv.names.5");
    pub const nv_names_7 = @embedFile("tests/names/tok3/nv.names.7");
    pub const nv_names_9 = @embedFile("tests/names/tok3/nv.names.9");
    pub const rr_names_1 = @embedFile("tests/names/tok3/rr.names.1");
    pub const rr_names_11 = @embedFile("tests/names/tok3/rr.names.11");
    pub const rr_names_13 = @embedFile("tests/names/tok3/rr.names.13");
    pub const rr_names_15 = @embedFile("tests/names/tok3/rr.names.15");
    pub const rr_names_17 = @embedFile("tests/names/tok3/rr.names.17");
    pub const rr_names_19 = @embedFile("tests/names/tok3/rr.names.19");
    pub const rr_names_3 = @embedFile("tests/names/tok3/rr.names.3");
    pub const rr_names_5 = @embedFile("tests/names/tok3/rr.names.5");
    pub const rr_names_7 = @embedFile("tests/names/tok3/rr.names.7");
    pub const rr_names_9 = @embedFile("tests/names/tok3/rr.names.9");
};
