//! Encode/decode compatibility for every codec the facade exposes.
//!
//! These round trips supplement the independent fixtures: they prove that
//! the caller-buffer and owned paths agree byte for byte, that each order
//! and method flag survives a round trip, and that the run-length and
//! bit-packing building blocks still compose.

const std = @import("std");
const htscodecs = @import("htscodecs");
const fx = @import("fixtures");
const provider = @import("provider.zig");

const flag = htscodecs.order_flag;
const aflag = htscodecs.arith_order_flag;

/// Orders exercised against the rANS 4x16 and arithmetic codecs.  Both
/// formats use the same bit positions; only the meaning of 0x04 differs
/// (X32 for rANS, X_EXT for arithmetic), so the X32 row is marked as not
/// applicable to the arithmetic coder and the bzip2 method is not used at
/// all.
const orders = [_]struct { name: []const u8, rans: c_int, arith: c_int }{
    .{ .name = "order0", .rans = 0, .arith = 0 },
    .{ .name = "order1", .rans = 1, .arith = 1 },
    .{ .name = "x32", .rans = flag.x32, .arith = -1 },
    .{ .name = "rle", .rans = flag.rle, .arith = aflag.rle },
    .{ .name = "rle+order1", .rans = flag.rle | 1, .arith = aflag.rle | 1 },
    .{ .name = "pack", .rans = flag.pack, .arith = aflag.pack },
    .{ .name = "pack+order1", .rans = flag.pack | 1, .arith = aflag.pack | 1 },
    .{ .name = "rle+pack", .rans = flag.rle | flag.pack, .arith = aflag.rle | aflag.pack },
    .{ .name = "rle+pack+order1", .rans = flag.rle | flag.pack | 1, .arith = aflag.rle | aflag.pack | 1 },
    .{ .name = "stripe4", .rans = flag.stripe | (4 << 8), .arith = aflag.stripe | (4 << 8) },
    .{ .name = "stripe4+order1", .rans = flag.stripe | 1 | (4 << 8), .arith = aflag.stripe | 1 | (4 << 8) },
};

/// A short, fully deterministic input that is not derived from any fixture,
/// used where a tiny buffer keeps the test readable.
const tiny = "abracadabra banana bandana";

test "rANS 4x8 round trips order-0 and order-1" {
    try provider.load();
    inline for (.{ 0, 1 }) |order| {
        const owned = try htscodecs.rans4x8.compress(tiny, order);
        defer owned.deinit();
        const back = try htscodecs.rans4x8.uncompress(owned.slice());
        defer back.deinit();
        try std.testing.expectEqualSlices(u8, tiny, back.slice());
    }
}

test "rANS 4x8 treats any non-zero order as order-1" {
    try provider.load();
    // rans_compress upstream is `return order ? O1 : O0;`, so order 2 is
    // not an error, it is order-1.  Pinning that keeps a caller from
    // assuming an out-of-range order is rejected.
    const one = try htscodecs.rans4x8.compress(tiny, 1);
    defer one.deinit();
    const two = try htscodecs.rans4x8.compress(tiny, 2);
    defer two.deinit();
    try std.testing.expectEqualSlices(u8, one.slice(), two.slice());
}

test "rANS 4x16 caller-buffer output is identical to the owned output" {
    try provider.load();
    const raw = try std.testing.allocator.alloc(u8, fx.source.q4.len);
    defer std.testing.allocator.free(raw);
    const payload = fx.qualityPayload(fx.source.q4, raw);

    for (orders) |entry| {
        const bound = try htscodecs.rans4x16.compressBound(payload.len, entry.rans);
        try std.testing.expect(bound >= payload.len);

        const scratch = try std.testing.allocator.alloc(u8, bound);
        defer std.testing.allocator.free(scratch);
        const n = try htscodecs.rans4x16.compressTo(payload, scratch, entry.rans);
        try std.testing.expect(n <= bound);

        const owned = try htscodecs.rans4x16.compress(payload, entry.rans);
        defer owned.deinit();
        try std.testing.expectEqual(owned.len, n);
        try std.testing.expectEqualSlices(u8, owned.slice(), scratch[0..n]);

        const plain = try std.testing.allocator.alloc(u8, payload.len);
        defer std.testing.allocator.free(plain);
        const m = try htscodecs.rans4x16.uncompressTo(scratch[0..n], plain);
        try std.testing.expectEqual(payload.len, m);
        try std.testing.expectEqualSlices(u8, payload, plain);
    }
}

test "the 32x16 kernels round trip through caller buffers" {
    try provider.load();
    const raw = try std.testing.allocator.alloc(u8, fx.source.q8.len);
    defer std.testing.allocator.free(raw);
    const payload = fx.qualityPayload(fx.source.q8, raw);

    const plain = try std.testing.allocator.alloc(u8, payload.len);
    defer std.testing.allocator.free(plain);

    for ([_]c_int{ 0, 1 }) |order| {
        // Each kernel derives its own bound from the order it is about to
        // encode and refuses a smaller destination
        // (`rANS_static32x16pr.c:84` and `:428`).  The order-1 bound is the
        // large one, because `rans_compress_bound_4x16` reserves the whole
        // 256x256 order-1 frequency table for it, so one buffer sized for
        // order 0 is rejected for order 1.
        const bound = try htscodecs.rans4x16.compressBound(payload.len, order);
        const scratch = try std.testing.allocator.alloc(u8, bound);
        defer std.testing.allocator.free(scratch);

        const n = try htscodecs.rans32x16.compressTo(payload, scratch, order);
        const m = try htscodecs.rans32x16.uncompressTo(scratch[0..n], plain, order);
        try std.testing.expectEqual(payload.len, m);
        try std.testing.expectEqualSlices(u8, payload, plain);
    }
}

test "the 32x16 wrappers reject an order they do not implement" {
    try provider.load();
    var scratch: [64]u8 = undefined;
    try std.testing.expectError(
        htscodecs.Error.InvalidArgument,
        htscodecs.rans32x16.compressTo(tiny, &scratch, 2),
    );
    try std.testing.expectError(
        htscodecs.Error.InvalidArgument,
        htscodecs.rans32x16.uncompressTo(tiny, &scratch, 7),
    );
}

test "the arithmetic coder caller-buffer output is identical to the owned output" {
    try provider.load();
    const raw = try std.testing.allocator.alloc(u8, fx.source.qvar.len);
    defer std.testing.allocator.free(raw);
    const payload = fx.qualityPayload(fx.source.qvar, raw);

    for (orders) |entry| {
        if (entry.arith < 0) continue;
        const bound = try htscodecs.arith.compressBound(payload.len, entry.arith);
        try std.testing.expect(bound >= payload.len);

        const scratch = try std.testing.allocator.alloc(u8, bound);
        defer std.testing.allocator.free(scratch);
        const n = try htscodecs.arith.compressTo(payload, scratch, entry.arith);
        try std.testing.expect(n <= bound);

        const owned = try htscodecs.arith.compress(payload, entry.arith);
        defer owned.deinit();
        try std.testing.expectEqual(owned.len, n);
        try std.testing.expectEqualSlices(u8, owned.slice(), scratch[0..n]);

        const plain = try std.testing.allocator.alloc(u8, payload.len);
        defer std.testing.allocator.free(plain);
        const m = try htscodecs.arith.uncompressTo(scratch[0..n], plain);
        try std.testing.expectEqual(payload.len, m);
        try std.testing.expectEqualSlices(u8, payload, plain);
    }
}

test "fqzcomp round trips a multi-record quality block" {
    try provider.load();
    // Two records of different lengths, the second flagged second-in-pair,
    // which is the shape CRAM actually stores.  The length and flag arrays
    // are mutable because the codec rewrites both.
    const first = "IIIIIIIIIIIIIIIIIIIII";
    const second = "#########";
    const payload = try std.testing.allocator.alloc(u8, first.len + second.len);
    defer std.testing.allocator.free(payload);
    for (first, 0..) |byte, i| payload[i] = byte - 33;
    for (second, 0..) |byte, i| payload[first.len + i] = byte - 33;
    const before = try std.testing.allocator.dupe(u8, payload);
    defer std.testing.allocator.free(before);

    var lens = [_]u32{ first.len, second.len };
    var flags = [_]u32{ 0, htscodecs.fqzcomp.flag_read2 };
    const slice = htscodecs.Slice{
        .num_records = 2,
        .len = &lens,
        .flags = &flags,
    };

    const encoded = try htscodecs.fqzcomp.compress(htscodecs.fqzcomp.vers_4_0, slice, payload, 0);
    defer encoded.deinit();

    // CRAM 4.0 stores qualities in their original orientation, so a 4.0
    // stream must leave the quality bytes alone even though the metadata
    // was rewritten.
    try std.testing.expectEqualSlices(u8, before, payload);

    const lengths = try std.testing.allocator.alloc(c_int, 2);
    defer std.testing.allocator.free(lengths);
    const back = try htscodecs.fqzcomp.decompressLengths(encoded.slice(), lengths);
    defer back.deinit();

    try std.testing.expectEqualSlices(u8, payload, back.slice());
    try std.testing.expectEqual(@as(c_int, first.len), lengths[0]);
    try std.testing.expectEqual(@as(c_int, second.len), lengths[1]);
}

test "fqzcomp clamps record lengths that do not sum to the input" {
    try provider.load();
    // The documented mutation, exercised directly.  One record is declared
    // far longer than the block; the codec must shorten it rather than
    // read past `in`.
    const payload = try std.testing.allocator.alloc(u8, 64);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast('!' + (i % 8));

    var lens = [_]u32{4096};
    var flags = [_]u32{0};
    const slice = htscodecs.Slice{
        .num_records = 1,
        .len = &lens,
        .flags = &flags,
    };

    const encoded = try htscodecs.fqzcomp.compress(htscodecs.fqzcomp.vers_4_0, slice, payload, 0);
    defer encoded.deinit();

    // The declared length now matches the block, not what we passed.
    try std.testing.expectEqual(@as(u32, @intCast(payload.len)), lens[0]);

    const back = try htscodecs.fqzcomp.decompress(encoded.slice());
    defer back.deinit();
    try std.testing.expectEqualSlices(u8, payload, back.slice());
}

test "fqzcomp gives a CRAM 3.1 flagged record back unchanged" {
    try provider.load();
    // A 3.1 stream stores qualities in the opposite orientation, so the
    // codec reverses every flagged record of the caller's buffer before it
    // encodes it (`fqzcomp_qual.c:1087-1109`) and reverses it back before it
    // returns (`:1193-1217`).  A caller sees its own bytes again after a
    // successful call, and that is the property it has to be able to rely
    // on, because whether `in` needs repairing depends on the outcome.
    const payload = try std.testing.allocator.alloc(u8, 32);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast('A' + i);
    const before = try std.testing.allocator.dupe(u8, payload);
    defer std.testing.allocator.free(before);

    var lens = [_]u32{@intCast(payload.len)};
    var flags = [_]u32{htscodecs.fqzcomp.flag_reverse};
    const slice = htscodecs.Slice{
        .num_records = 1,
        .len = &lens,
        .flags = &flags,
    };

    const encoded = try htscodecs.fqzcomp.compress(htscodecs.fqzcomp.vers_3_1, slice, payload, 0);
    defer encoded.deinit();

    try std.testing.expectEqualSlices(u8, before, payload);

    // The stream carries the reversed orientation and the decoder undoes
    // that too (`:1575-1589`), so the round trip returns the input.
    const back = try htscodecs.fqzcomp.decompress(encoded.slice());
    defer back.deinit();
    try std.testing.expectEqualSlices(u8, before, back.slice());
}

test "the read-name tokeniser round trips at several levels" {
    try provider.load();
    const template = "@ERR174310.1 HSQ1008_141:5:1101:1454:3564/1\n" ++
        "@ERR174310.2 HSQ1008_141:5:1101:1485:3570/1\n" ++
        "@ERR174310.3 HSQ1008_141:5:1101:1407:3580/1\n";

    for ([_]c_int{ 1, 5, 9, 13, 19 }) |level| {
        // encodeNames rewrites the separators in place, so each level gets
        // its own copy.  That is the contract, not an accident of the test.
        const block = try std.testing.allocator.dupe(u8, template);
        defer std.testing.allocator.free(block);

        const encoded = try htscodecs.tok3.encodeNames(block, level, false, null);
        defer encoded.deinit();

        // The separators really were destroyed, which is why the parameter
        // is `[]u8` and not `[]const u8`.
        for (block) |byte| {
            try std.testing.expect(byte != '\n');
        }

        const back = try htscodecs.tok3.decodeNames(encoded.slice());
        defer back.deinit();
        try std.testing.expectEqual(template.len, back.len);
        const rebuilt = try fx.splitNames(std.testing.allocator, back.slice());
        defer std.testing.allocator.free(rebuilt);
        try std.testing.expectEqualSlices(u8, template, rebuilt);
    }
}

test "the tokeniser encodes only whole records and says where the rest starts" {
    try provider.load();
    // A block cut mid-line still encodes.  Upstream encodes whole lines
    // only: its trie loop stops at the first byte it cannot find a
    // separator for (`tokenise_name3.c:1469-1481`), so `last_start` is the
    // offset of the trailing partial record and the stream covers exactly
    // the prefix before it.  A streaming caller carries the remainder over
    // itself, which is what `tests/tokenise_name3_test.c:157-159` does
    // with its `memmove`.
    const template = "read-one\nread-two\nread-three\n";
    const complete = "read-one\nread-two\n";
    const cut_len = template.len - 6;

    const cut = try std.testing.allocator.dupe(u8, template[0..cut_len]);
    defer std.testing.allocator.free(cut);

    var last_start: c_int = -1;
    const encoded = try htscodecs.tok3.encodeNames(cut, 5, false, &last_start);
    defer encoded.deinit();

    try std.testing.expectEqual(@as(c_int, complete.len), last_start);

    const back = try htscodecs.tok3.decodeNames(encoded.slice());
    defer back.deinit();
    try std.testing.expectEqual(@as(usize, complete.len), back.len);
    const rebuilt = try fx.splitNames(std.testing.allocator, back.slice());
    defer std.testing.allocator.free(rebuilt);
    try std.testing.expectEqualSlices(u8, complete, rebuilt);
}

test "run-length coding round trips and reports its symbol set" {
    try provider.load();
    // Few distinct symbols and long runs, which is what the RLE method
    // exists for.
    var data: [4096]u8 = undefined;
    for (&data, 0..) |*byte, i| {
        byte.* = switch (i / 512) {
            0 => 'A',
            1 => 'B',
            2 => 'C',
            3 => 'D',
            else => 'E',
        };
    }

    var run: [data.len]u8 = undefined;
    var out: [2 * data.len]u8 = undefined;
    var syms = htscodecs.rle.Symbols{};

    const written = try htscodecs.rle.encode(&data, &run, &syms, &out);

    const back = try std.testing.allocator.alloc(u8, data.len);
    defer std.testing.allocator.free(back);
    const n = try htscodecs.rle.decode(out[0..written.out_len], run[0..written.run_len], &syms, back);
    try std.testing.expectEqual(data.len, n);
    try std.testing.expectEqualSlices(u8, &data, back);
}

test "symbol packing round trips a four-symbol alphabet" {
    try provider.load();
    var data: [1000]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = "ACGT"[i % 4];

    var meta = htscodecs.pack.Meta{};
    const encoded = try htscodecs.pack.packData(&data, &meta);
    defer encoded.deinit();
    try std.testing.expectEqual(@as(usize, 5), @as(usize, @intCast(meta.meta_len)));

    var map: [256]u8 = @splat(0);
    const header = try htscodecs.pack.unpackMeta(meta.map[0..], @intCast(data.len), map[0..]);
    // Four symbols means four values per packed byte.
    try std.testing.expectEqual(@as(c_int, 4), header.nsym);

    const back = try std.testing.allocator.alloc(u8, data.len);
    defer std.testing.allocator.free(back);
    const n = try htscodecs.pack.unpackTo(encoded.slice(), back, header.nsym, map[0..]);
    try std.testing.expectEqual(data.len, n);
    try std.testing.expectEqualSlices(u8, &data, back);
}

test "a full 256-symbol alphabet fills the map without reaching the length field" {
    try provider.load();
    // hts_pack writes the whole map before it checks the alphabet width,
    // and the 256th symbol's code lands on index 256 (pack.c:68).  With
    // a 256-byte map that byte is `meta_len`, so the sentinel below would
    // be destroyed.  This is the regression that pins the extra byte.
    var data: [256]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @intCast(i);

    var meta = htscodecs.pack.Meta{ .meta_len = 0x5a5a };
    try std.testing.expectError(
        htscodecs.Error.OperationFailed,
        htscodecs.pack.packData(&data, &meta),
    );

    // The map write went into the spare byte, not into meta_len.
    try std.testing.expectEqual(@as(c_int, 0x5a5a), meta.meta_len);
    try std.testing.expectEqual(@as(u8, 255), meta.map[256]);
    // 256 codes wrap to zero, which is upstream's own encoding of "all".
    try std.testing.expectEqual(@as(u8, 0), meta.map[0]);
}

test "unpacking an unpacked stream into a short destination is refused" {
    try provider.load();
    // `nsym == 1` means "not packed", which unpackMeta returns for an
    // alphabet wider than 16 symbols.  Upstream then memcpy's the whole
    // input into out and never looks at the destination length
    // (pack.c:212-215), so the check has to happen here.
    const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const map: [256]u8 = @splat(0);

    var short: [4]u8 = undefined;
    try std.testing.expectError(
        htscodecs.Error.BufferTooSmall,
        htscodecs.pack.unpackTo(&data, &short, 1, &map),
    );

    // The exact size is the documented case and must still work.
    var exact: [8]u8 = undefined;
    const n = try htscodecs.pack.unpackTo(&data, &exact, 1, &map);
    try std.testing.expectEqual(@as(usize, data.len), n);
    try std.testing.expectEqualSlices(u8, &data, &exact);
}

test "a symbol map one byte short is refused before the C code touches it" {
    try provider.load();
    // The length check on the public map slices is an ordinary runtime
    // comparison, not a debug assertion, so it holds in ReleaseFast too.
    //
    // The encoded metadata is written out here rather than produced by
    // `packData`, so the oracle is `pack.c` and not this fork: `data[0]` is
    // the number of used symbols, the bytes after it are those symbols
    // (`:167`-`:191`), and three to sixteen of them mean four symbols per
    // byte (`:176`).
    const header = [_]u8{ 4, 'A', 'C', 'G', 'T' };
    const udata_len: u64 = 8;

    // `pack.Meta.map` is 257 bytes because `hts_pack` writes index 256
    // before it can fail; a reader needs 256.  255 is therefore one below
    // both, and is the boundary the guard sits on.
    var meta = htscodecs.pack.Meta{};

    try std.testing.expectError(
        htscodecs.Error.InvalidArgument,
        htscodecs.pack.unpackMeta(&header, udata_len, meta.map[0..255]),
    );

    var out: [8]u8 = undefined;
    try std.testing.expectError(
        htscodecs.Error.InvalidArgument,
        htscodecs.pack.unpackTo(&header, &out, 1, meta.map[0..255]),
    );

    // 256 is enough for a reader, and the four symbols really are read
    // back rather than merely tolerated.
    const parsed = try htscodecs.pack.unpackMeta(&header, udata_len, meta.map[0..256]);
    try std.testing.expectEqual(@as(c_int, 4), parsed.nsym);
    try std.testing.expectEqual(@as(usize, header.len), parsed.consumed);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 'A', 'C', 'G', 'T' }, meta.map[0..4]);

    // The shipped 257-byte field is one more than a reader needs and is
    // accepted whole; with `nsym == 1` upstream copies the metadata across
    // unchanged, so the length reported is the length it wrote.
    const n = try htscodecs.pack.unpackTo(&header, &out, 1, meta.map[0..]);
    try std.testing.expectEqual(@as(usize, header.len), n);
    try std.testing.expectEqualSlices(u8, &header, out[0..n]);
}
