//! Idiomatic Zig facade over the upstream htscodecs C library.
//!
//! This file adds no algorithms.  Every function is a thin, audited wrapper
//! around the matching entry point in the `c` module (the translation of
//! include/htscodecs_all.h), and the raw C surface stays reachable through
//! `htscodecs.c` for anything the facade does not cover.
//!
//! Three rules shape the wrappers:
//!
//! 1. Ownership is explicit.  Where upstream has a `*_to` entry point that
//!    writes into a caller buffer, the wrapper writes into yours and returns
//!    the used length; nothing is allocated.  Where upstream only offers a
//!    `malloc`ing entry point, the wrapper returns an `Owned` that wraps the
//!    C pointer and frees it with the C allocator in `deinit`.  No Zig
//!    allocator is involved and no process-global hook is installed.
//! 2. Length narrowing is checked.  Upstream takes `unsigned int` and
//!    rejects anything above `INT_MAX`; the wrappers return
//!    `error.LengthOverflow` before the call instead of truncating.
//! 3. Aliasing is rejected, in every build mode.  Upstream reads one region
//!    while writing another, so they must not overlap; a wrapper that finds
//!    them overlapping returns `error.InvalidArgument` before the call,
//!    rather than let the result depend on the order the C code happens to
//!    touch the bytes.  The check is an ordinary comparison, so a
//!    ReleaseFast build refuses it too.
//!
//! Upstream reports failure as a NULL return, and does not distinguish
//! "the stream is invalid" from "allocation failed" (or, for the encoding
//! side, from "your buffer is too small").  The wrappers cannot recover
//! information upstream threw away, so they map NULL as documented on each
//! function rather than inventing a distinction.

const std = @import("std");

/// Complete translated C interface, as produced by b.addTranslateC over
/// include/htscodecs_all.h.  Use it directly for anything the named
/// wrappers below do not cover.
pub const c = @import("c");

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Failures reported by the facade.
///
/// The line between these is whether *the facade* knows the cause.  A NULL
/// from upstream carries no reason, so anything derived from one is
/// `OperationFailed` and nothing more specific.  Only an argument the
/// facade inspects itself, before calling, earns a name of its own.
pub const Error = error{
    /// A length does not fit the `unsigned int` / `int` size upstream uses.
    /// Upstream rejects inputs above `INT_MAX` too; refusing here keeps
    /// that a length problem rather than an unexplained NULL.
    LengthOverflow,

    /// The facade rejected the argument itself, before calling upstream:
    /// an order byte the chosen kernel does not implement, a record array
    /// whose length contradicts `Slice.num_records`, a symbol map shorter
    /// than the 256 bytes the C code reads and writes, an `rle.Symbols`
    /// count outside the 256-entry array, or an input and an output that
    /// overlap.  Fixing the argument is the whole remedy.
    InvalidArgument,

    /// The facade compared two lengths the caller supplied and knows the
    /// destination cannot hold the result: a zero-length destination, a
    /// `rle.encode` whose `run` or `out` is smaller than the size that
    /// call documents as required, or a stream that `pack.unpackTo` would
    /// copy past its destination.  This is the only error a caller can act
    /// on by resizing and retrying.
    BufferTooSmall,

    /// Upstream returned NULL, and the C API does not say why.  Depending
    /// on the call, that may mean the stream was malformed, the capacity
    /// was insufficient, the method is compiled out (the arithmetic
    /// coder's `ext` without `-Dbz2=true`), or an allocation failed.  None
    /// of those is distinguishable from the others through `htscodecs.c`,
    /// so this says only what is true: the operation did not succeed.
    /// Read the doc on the function that produced it for what its own NULL
    /// can mean.
    OperationFailed,
};

/// Upstream's own hard ceiling.  Every `*_size` argument is an
/// `unsigned int`, and the encoders explicitly test `in_size > INT_MAX`.
pub const max_stream_len: usize = std.math.maxInt(c_int);

// ---------------------------------------------------------------------------
// Owned results
// ---------------------------------------------------------------------------

/// A buffer that upstream allocated with `malloc` and that the caller owns.
///
/// `slice` is a window on that allocation and `deinit` releases it, so the
/// two together account for every byte: there is no second buffer to
/// free.  `deinit` calls the C allocator's `free`, which is the correct
/// pairing for upstream's `malloc`.  Nothing here touches a Zig allocator,
/// so an `Owned` may be produced in one context and released in another.
pub const Owned = struct {
    ptr: [*]u8,
    len: usize,

    /// The owned bytes.  Valid until `deinit`.
    pub fn slice(self: Owned) []u8 {
        return self.ptr[0..self.len];
    }

    /// Releases the buffer with the C allocator that produced it.
    pub fn deinit(self: Owned) void {
        cFree(self.ptr);
    }
};

/// Frees a pointer obtained from upstream's `malloc`-ing entry points.
/// Exposed so callers holding a raw pointer from the `c` module can release
/// it correctly too.
pub fn cFree(ptr: ?[*]u8) void {
    if (ptr) |p| std.c.free(@ptrCast(p));
}

/// Narrows a slice length to upstream's `unsigned int`, refusing anything
/// upstream itself would reject.
inline fn narrow(len: usize) Error!c_uint {
    if (len > max_stream_len) return error.LengthOverflow;
    return @intCast(len);
}

/// Narrows a slice length to upstream's `int`.
inline fn narrowInt(len: usize) Error!c_int {
    if (len > max_stream_len) return error.LengthOverflow;
    return @intCast(len);
}

/// Produces the `unsigned char *` / `uint8_t *` that upstream's prototypes
/// ask for, discarding constness.
///
/// This is *not* a general claim that upstream never writes its input.
/// Two of the entry points do:
///
///   * `tok3_encode_names` rewrites every `\n` or `\0` separator in the
///     block to `\0` before encoding (`tokenise_name3.c:1500`), which is
///     why `tok3.encodeNames` takes `[]u8` and says so.
///   * `fqz_compress` clamps the caller's `fqz_slice.len` and ORs selector
///     bits into `fqz_slice.flags` (`fqzcomp_qual.c:589`, `:596`, `:790`,
///     `:795`), and for a CRAM 3.1 stream it reverses each flagged record
///     of `in` in place before encoding (`:1087`-`:1109`), which is why
///     `fqzcomp.compress` takes mutable borrows and says so.
///
/// Every other call through this helper is genuinely read-only.  The two
/// exceptions are enforced at the signature, where a caller can see them,
/// rather than hidden behind a `@constCast` here.
inline fn cPtr(bytes: []const u8) [*c]u8 {
    return @ptrCast(@constCast(bytes.ptr));
}

/// Produces the `char *` that upstream's `fqz_compress` and
/// `fqz_decompress` ask for, from a buffer the caller only reads.
/// Neither looks for a terminator: both work from an explicit length.
/// `fqz_compress` does write through it, for the reasons given on
/// `cPtr`; `fqz_decompress` does not, which is why this one takes a
/// `[]const u8` and `cStrMut` exists for the callers that must not.
inline fn cStr(bytes: []const u8) [*:0]u8 {
    return @ptrCast(@constCast(bytes.ptr));
}

/// Produces the `char *` for a caller's own, mutable, buffer, where
/// upstream writes through it.  `tok3_encode_names` does, so the caller
/// has to own writable memory; see the note on `cStr`.
inline fn cStrMut(bytes: []u8) [*:0]u8 {
    return @ptrCast(bytes.ptr);
}

/// Produces the `uint8_t *` for a caller's symbol map.
///
/// The length precondition is checked, not assumed, because upstream is
/// inconsistent about it: the maps `hts_unpack_meta` and `hts_unpack` read
/// are 256 bytes, while the map `hts_pack` writes needs 257 — see
/// `pack.Meta.map`.  Making every map a slice with a checked length
/// removes the chance of picking the wrong one at a call site.
///
/// The `assert` here is a redundant net, **not** the guard.  It vanishes in
/// ReleaseFast and ReleaseSmall.  The guard is the explicit
/// `map.len < min_map_len` test in `pack.unpackMeta` and `pack.unpackTo`,
/// which runs in every build mode and returns `error.InvalidArgument`
/// before the C code can read or write the map; do not remove those on the
/// strength of this line.  The two other callers pass fixed-size fields
/// (`pack.Meta.map`, 257 bytes; `rle.Symbols.syms`, 256) whose length is
/// known at compile time.
inline fn cMap(map: []const u8) [*c]u8 {
    std.debug.assert(map.len >= min_map_len);
    return @ptrCast(@constCast(map.ptr));
}

/// The smallest symbol map any of these entry points will touch.
const min_map_len = 256;

/// Produces the `unsigned char *` for a caller-owned destination buffer.
inline fn cOutBuf(buf: []u8) [*c]u8 {
    return @ptrCast(buf.ptr);
}

/// Produces the `int *` for a caller-owned destination buffer.  Upstream
/// allows that pointer to be NULL, so the result is passed where an
/// optional pointer is expected.
inline fn cIntBuf(buf: []c_int) [*c]c_int {
    return @ptrCast(buf.ptr);
}

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a0 = @intFromPtr(a.ptr);
    const b0 = @intFromPtr(b.ptr);
    return a0 < b0 + b.len and b0 < a0 + a.len;
}

/// The aliasing guard the `*_to` wrappers need.  Upstream reads one region
/// while writing another, so overlapping buffers make the result depend on
/// the order the C code happens to touch the bytes.  This is an ordinary
/// comparison that returns `error.InvalidArgument` before the call in
/// every build mode, ReleaseFast and ReleaseSmall included, because the
/// public contract is that error and not a debug assertion: a guard that
/// vanishes in a release build would document a promise the library stops
/// keeping exactly where a caller is least able to notice.
inline fn checkDisjoint(in: []const u8, out: []u8) Error!void {
    if (overlaps(in, out)) return error.InvalidArgument;
}

/// Whether a pointer a translated C function returned is NULL.
///
/// `b.addTranslateC` builds an optional single pointer only when the child
/// type is opaque or a function
/// (`lib/compiler/translate-c/Translator.zig:1215-1237`), so a
/// declaration such as `unsigned char *rans_compress_to_4x16(...)` arrives
/// as `[*c]u8` even though the C function does return NULL on failure.
/// The test is the address, not an optional coercion: assigning a `[*c]u8`
/// to a `?[*c]u8` does not reliably map address 0 to null, and a guard that
/// misses it turns every upstream NULL return into a null-pointer panic
/// inside the next cast instead of an `error.OperationFailed`.
inline fn cIsNull(ptr: [*c]u8) bool {
    return @intFromPtr(ptr) == 0;
}

/// Turns upstream's NULL return into an `Owned` of the given length.
inline fn owned(raw: [*c]u8, len: usize) Error!Owned {
    if (cIsNull(raw)) return error.OperationFailed;
    const ptr: [*]u8 = @ptrCast(raw);
    return .{ .ptr = ptr, .len = len };
}

// ---------------------------------------------------------------------------
// Order / method flag bits
// ---------------------------------------------------------------------------

/// Order-byte bits for the rANS 4x16 codec, copied from rANS_static4x16.h.
/// The low two bits are the order itself (0 or 1); the rest select
/// transforms and the encoder strategy.  These values are part of the file
/// format.
pub const order_flag = struct {
    /// Pack 2, 4 or 8 symbols into a byte.
    pub const pack: c_int = 0x80;
    /// Run-length encode, with runs and literals stored separately.
    pub const rle: c_int = 0x40;
    /// Store the input verbatim; used for tiny blocks where codec overhead
    /// would dominate.
    pub const cat: c_int = 0x20;
    /// Omit the stored original size (STRIPE sub-mode only).
    pub const nosz: c_int = 0x10;
    /// Interleave N byte-rotated streams.  N occupies bits 8-15.
    pub const stripe: c_int = 0x08;
    /// 32-way unrolling instead of 4-way.
    pub const x32: c_int = 0x04;
    /// Bits 8-15 carry the stripe size N for `stripe`.
    pub const stripe_shift: u5 = 8;
    /// Disable order-0 inside the STRIPE sub-methods.
    pub const stripe_no0: c_int = 1 << 16;
    /// Let the encoder pick 4-way or 32-way unrolling itself.
    pub const simd_auto: c_int = 1 << 17;
};

/// CPU-selection bits for `ransSetCpu`, from rANS_static4x16.h.  Only
/// useful for benchmarking one kernel against another on the same machine.
pub const cpu_flag = struct {
    pub const enc_sse4: c_int = 1 << 0;
    pub const enc_avx2: c_int = 2 << 0;
    pub const enc_avx512: c_int = 4 << 0;
    pub const enc_neon: c_int = 8 << 0;
    pub const dec_sse4: c_int = 1 << 8;
    pub const dec_avx2: c_int = 2 << 8;
    pub const dec_avx512: c_int = 4 << 8;
    pub const dec_neon: c_int = 8 << 8;

    /// Every kernel permitted, which is the value the library starts with.
    /// `rans_set_cpu` assigns its argument outright, so this, not zero, is
    /// what restores automatic selection.
    pub const all: c_int = 0xFFFF;
    /// No kernel permitted: the 4-way scalar encoder and decoder.  A
    /// round trip must still reproduce the input in this configuration.
    pub const none: c_int = 0;
};

/// Restricts which 32x16 kernels the library may select at run time.
/// The value replaces the current mask outright; pass `cpu_flag.all` to
/// restore automatic detection, `cpu_flag.none` to force the scalar path.
pub fn ransSetCpu(flags: c_int) void {
    c.rans_set_cpu(flags);
}

/// Library version as the packed `HTSCODECS_VERSION` integer (X.Y.Z encoded
/// as XYYYZZ, so 1.6.7 is 100607).
pub fn version() c_int {
    return c.HTSCODECS_VERSION;
}

/// Library version as upstream's `htscodecs_version()` string.  The bytes
/// belong to the library and must not be freed.  The C declaration is
/// `const char *`, which translates to a non-optional `[*c]const u8`, so
/// the sentinel-terminated form the facade publishes is a cast.
pub fn versionText() [*:0]const u8 {
    return @ptrCast(c.htscodecs_version());
}

// ---------------------------------------------------------------------------
// rANS 4x8  (rANS_static.c)
// ---------------------------------------------------------------------------

/// The byte-oriented rANS codec.  Upstream offers no caller-buffer variant
/// for this one, so both directions return an `Owned`.
pub const rans4x8 = struct {
    /// Order-0 for `order == 0`, order-1 for any other value.  Upstream's
    /// `rans_compress` is literally `return order ? O1 : O0;`, so an
    /// out-of-range order is treated as order-1 rather than rejected.
    pub fn compress(in: []const u8, order: c_int) Error!Owned {
        var out_size: c_uint = 0;
        return owned(c.rans_compress(cPtr(in), try narrow(in.len), &out_size, order), out_size);
    }

    /// Decodes a stream produced by `compress` or by any other
    /// implementation of the format.  Upstream rejects inputs shorter than
    /// 9 bytes, which surfaces here as `error.OperationFailed`.
    pub fn uncompress(compressed: []const u8) Error!Owned {
        var out_size: c_uint = 0;
        return owned(c.rans_uncompress(cPtr(compressed), try narrow(compressed.len), &out_size), out_size);
    }
};

// ---------------------------------------------------------------------------
// rANS 4x16  (rANS_static4x16pr.c)
// ---------------------------------------------------------------------------

/// The 16-bit-renormalisation rANS codec, including the run-length and
/// bit-packing transforms and the 32-way SIMD kernels.  Both directions
/// have caller-buffer forms, so nothing is allocated when you size the
/// destination yourself.
pub const rans4x16 = struct {
    /// Worst-case compressed size for `size` input bytes at `order`.  Use
    /// this to size the destination for `compressTo`.
    pub fn compressBound(size: usize, order: c_int) Error!usize {
        return c.rans_compress_bound_4x16(try narrow(size), order);
    }

    /// Compresses into `out`, which must not overlap `in`, and returns the
    /// number of bytes written.
    ///
    /// A NULL return is `error.OperationFailed`, not
    /// `error.BufferTooSmall`: upstream cannot tell us whether the
    /// destination was too small, an internal allocation failed, or
    /// something else went wrong.  Sizing `out` with `compressBound`
    /// removes the only cause the caller could act on.
    pub fn compressTo(in: []const u8, out: []u8, order: c_int) Error!usize {
        // The input length is narrowed before anything looks at `out`: it
        // is a property of `in` alone, so an input upstream could not
        // accept is a length problem whatever the destination is.
        const in_len = try narrow(in.len);
        try checkDisjoint(in, out);
        if (out.len == 0) return error.BufferTooSmall;
        var out_size: c_uint = try narrow(out.len);
        const raw = c.rans_compress_to_4x16(cPtr(in), in_len, cOutBuf(out), &out_size, order);
        if (cIsNull(raw)) return error.OperationFailed;
        return out_size;
    }

    /// Compresses into a buffer upstream allocates.  Use when the bound is
    /// only known at run time or when the destination cannot be reused.
    pub fn compress(in: []const u8, order: c_int) Error!Owned {
        var out_size: c_uint = 0;
        return owned(c.rans_compress_4x16(cPtr(in), try narrow(in.len), &out_size, order), out_size);
    }

    /// Decompresses into `out`, which must not overlap `compressed`, and
    /// returns the number of bytes written.
    ///
    /// For a stream carrying the `stripe` order bit the destination must be
    /// exactly the original size.  `rANS_static4x16pr.c:1619` compares the
    /// length it read from the stream against the capacity for *equality*
    /// (`if (ulen != *out_size) return NULL;`), so an over-sized buffer is
    /// rejected exactly as a short one is and surfaces as
    /// `error.OperationFailed`.  Every other order accepts a larger destination.
    ///
    /// In the non-stripe path a short destination is reported the same way:
    /// upstream returns NULL without writing the size it needed, so the two
    /// cases cannot be told apart.
    pub fn uncompressTo(compressed: []const u8, out: []u8) Error!usize {
        // The length is narrowed first, before anything looks at the
        // buffers.  An input too long for upstream's own argument type is a
        // length problem whatever the destination happens to be, and
        // checking aliasing first would report the unrelated
        // `error.InvalidArgument` for a slice that is never read anyway.
        const in_len = try narrow(compressed.len);
        try checkDisjoint(compressed, out);
        if (out.len == 0) return error.BufferTooSmall;
        var out_size: c_uint = try narrow(out.len);
        const raw = c.rans_uncompress_to_4x16(cPtr(compressed), in_len, cOutBuf(out), &out_size);
        if (cIsNull(raw)) return error.OperationFailed;
        return out_size;
    }

    /// Decompresses into a buffer upstream allocates, sized from the length
    /// stored in the stream.
    pub fn uncompress(compressed: []const u8) Error!Owned {
        var out_size: c_uint = 0;
        return owned(c.rans_uncompress_4x16(cPtr(compressed), try narrow(compressed.len), &out_size), out_size);
    }
};

// ---------------------------------------------------------------------------
// rANS 32x16  (rANS_static32x16pr.c)
// ---------------------------------------------------------------------------

/// The 32-way unrolled rANS kernels.  These are the raw per-ISA entry
/// points; the ordinary entry points are `rans4x16`, which selects a
/// kernel at run time.  Both upstream functions accept a caller buffer and
/// also allocate when `out` is NULL.
pub const rans32x16 = struct {
    /// `order` selects the order-0 or order-1 kernel.
    ///
    /// `out` must be at least `rans4x16.compressBound(in.len, order)`
    /// bytes, and the bound is per order: each kernel derives its own from
    /// `rans_compress_bound_4x16(in_size, order)` and refuses anything
    /// smaller (`rANS_static32x16pr.c:84` and `:428`), which for order 1
    /// reserves the whole 256x256 order-1 frequency table.  A destination
    /// under the bound is upstream's NULL, so it is
    /// `error.OperationFailed` here, not a resizable
    /// `error.BufferTooSmall`.
    ///
    /// Order 1 additionally needs at least 32 input bytes: below that
    /// upstream refuses rather than falling back to order-0
    /// (`rANS_static32x16pr.c:421`).
    pub fn compressTo(in: []const u8, out: []u8, order: c_int) Error!usize {
        if (order != 0 and order != 1) return error.InvalidArgument;
        const in_len = try narrow(in.len);
        try checkDisjoint(in, out);
        if (out.len == 0) return error.BufferTooSmall;
        var out_size: c_uint = try narrow(out.len);
        const raw = switch (order) {
            0 => c.rans_compress_O0_32x16(cPtr(in), in_len, cOutBuf(out), &out_size),
            else => c.rans_compress_O1_32x16(cPtr(in), in_len, cOutBuf(out), &out_size),
        };
        if (cIsNull(raw)) return error.OperationFailed;
        return out_size;
    }

    /// `out` must already be the exact uncompressed size: the 32x16 streams
    /// do not store it.  Returns `out.len` on success.
    pub fn uncompressTo(compressed: []const u8, out: []u8, order: c_int) Error!usize {
        if (order != 0 and order != 1) return error.InvalidArgument;
        const in_len = try narrow(compressed.len);
        try checkDisjoint(compressed, out);
        if (out.len == 0) return error.BufferTooSmall;
        if (out.len >= max_stream_len) return error.LengthOverflow;
        const out_size: c_uint = @intCast(out.len);
        const raw = switch (order) {
            0 => c.rans_uncompress_O0_32x16(cPtr(compressed), in_len, cOutBuf(out), out_size),
            else => c.rans_uncompress_O1_32x16(cPtr(compressed), in_len, cOutBuf(out), out_size),
        };
        if (cIsNull(raw)) return error.OperationFailed;
        return out.len;
    }
};

// ---------------------------------------------------------------------------
// Dynamic arithmetic coder  (arith_dynamic.c)
// ---------------------------------------------------------------------------

/// Order-byte bits for the dynamic arithmetic coder, copied from the
/// X_* defines at the top of arith_dynamic.c.  The numeric values happen
/// to match the rANS 4x16 set, which is why the names line up; the
/// difference is `ext`, the one method the arithmetic coder adds: it can
/// hand the block to an external compressor, and in this release that
/// means bzip2.
pub const arithOrderFlag = struct {
    /// Bit-pack the symbols.
    pub const pack: c_int = 0x80;
    /// Run-length encode, with runs and literals stored separately.
    pub const rle: c_int = 0x40;
    /// Store the input verbatim; used for tiny blocks where codec overhead
    /// would dominate.
    pub const cat: c_int = 0x20;
    /// Omit the stored original size (STRIPE sub-mode only).
    pub const nosz: c_int = 0x10;
    /// Interleave N byte-rotated streams; N occupies bits 8-15.
    pub const stripe: c_int = 0x08;
    /// Delegate to an external compressor (bzip2 in this release).  Needs
    /// a libbz2-enabled build; see the note on `arith`.
    pub const ext: c_int = 0x04;
    /// Mask that selects the order itself: 0 or 1.
    pub const order_mask: c_int = 0x03;
    /// Bits 8-15 carry the stripe size N for `stripe`.
    pub const stripe_shift: u5 = 8;
};

/// The dynamic arithmetic coder, with the same caller-buffer and owned
/// pairing as `rans4x16`.
///
/// The `ext` method needs libbz2.  Without `-Dbz2=true` the library is
/// compiled with that method out: upstream prints a diagnostic to stderr
/// and returns NULL, in both directions.  A stream written with bzip2
/// cannot be read back by a build without it, and asking such a build to
/// write one fails the same way.  Neither outcome is distinguishable from
/// any other NULL, so both surface as `error.OperationFailed`; see `Error`.
pub const arith = struct {
    /// Worst-case compressed size for `size` input bytes at `order`.
    pub fn compressBound(size: usize, order: c_int) Error!usize {
        return c.arith_compress_bound(try narrow(size), order);
    }

    /// Compresses into `out`, which must not overlap `in`, and returns the
    /// number of bytes written.
    ///
    /// A NULL return is `error.OperationFailed`, not
    /// `error.BufferTooSmall`: upstream cannot tell us whether the
    /// destination was too small, the method is compiled out, the input
    /// was rejected, or an allocation failed.  Sizing `out` with
    /// `compressBound` removes the first cause, and is the only way to do
    /// so, which is why it exists.
    pub fn compressTo(in: []const u8, out: []u8, order: c_int) Error!usize {
        const in_len = try narrow(in.len);
        try checkDisjoint(in, out);
        if (out.len == 0) return error.BufferTooSmall;
        var out_size: c_uint = try narrow(out.len);
        const raw = c.arith_compress_to(cPtr(in), in_len, cOutBuf(out), &out_size, order);
        if (cIsNull(raw)) return error.OperationFailed;
        return out_size;
    }

    /// Compresses into a buffer upstream allocates.
    pub fn compress(in: []const u8, order: c_int) Error!Owned {
        var out_size: c_uint = 0;
        return owned(c.arith_compress(cPtr(in), try narrow(in.len), &out_size, order), out_size);
    }

    /// Decompresses into `out`, which must not overlap `compressed`, and
    /// returns the number of bytes written.
    ///
    /// For a stream carrying the `stripe` order bit the destination must be
    /// exactly the original size: `arith_dynamic.c` compares the length it
    /// read from the stream against the capacity for equality
    /// (`if (ulen != *out_size) return NULL;`), so an over-sized buffer is
    /// rejected just as a short one is.  For every other order a larger
    /// destination is fine.
    pub fn uncompressTo(compressed: []const u8, out: []u8) Error!usize {
        const in_len = try narrow(compressed.len);
        try checkDisjoint(compressed, out);
        if (out.len == 0) return error.BufferTooSmall;
        var out_size: c_uint = try narrow(out.len);
        const raw = c.arith_uncompress_to(cPtr(compressed), in_len, cOutBuf(out), &out_size);
        if (cIsNull(raw)) return error.OperationFailed;
        return out_size;
    }

    /// Decompresses into a buffer upstream allocates.
    pub fn uncompress(compressed: []const u8) Error!Owned {
        var out_size: c_uint = 0;
        return owned(c.arith_uncompress(cPtr(compressed), try narrow(compressed.len), &out_size), out_size);
    }
};

// ---------------------------------------------------------------------------
// fqzcomp quality scores  (fqzcomp_qual.c)
// ---------------------------------------------------------------------------

/// Per-record metadata the fqzcomp codec needs: the length of each quality
/// string and its flags.  `flags` carries `fqzcomp.flag_read2` and, in bit
/// 16 and up, the parameter selector the codec borrows from it.
///
/// The borrows are mutable because the codec writes to them.  It clamps
/// `len` so the records sum to the input length
/// (`fqzcomp_qual.c:790`, `:795`) and ORs its chosen selector into `flags`
/// (`:589`, `:596`); before a successful `fqzcomp.compress` returns it
/// clears those borrowed bits again (`:1219`-`:1221`).  So after a
/// successful call `len` holds the clamped lengths and `flags` holds the
/// bits the caller passed, which is what the codec actually used.
pub const Slice = struct {
    num_records: usize,
    len: []u32,
    flags: []u32,
};

/// The fqzcomp quality-score codec, used by CRAM for read quality blocks.
pub const fqzcomp = struct {
    /// Bit set in `Slice.flags` for a second-in-pair read.
    pub const flag_read2: u32 = 128;
    /// Bit set in `Slice.flags` for a reverse-complemented read.
    pub const flag_reverse: u32 = 16;
    /// Current on-disk format version.
    pub const format_version: c_int = c.FQZ_VERS;
    /// Highest valid compression strategy.
    pub const max_strategy: c_int = c.FQZ_MAX_STRAT;
    /// The CRAM version whose streams store qualities in the opposite
    /// orientation, so the encoder reverses each flagged record before
    /// encoding it and the decoder reverses it back: upstream gates that
    /// on `vers == 3` (`fqzcomp_qual.c:763`) and names the two values
    /// "CRAM version 4.0 (4) or 3.1 (3)" in its own test driver
    /// (`fqzcomp_qual_test.c:322`).
    pub const vers_3_1: c_int = 3;
    /// CRAM 4.0 stream; see `vers_3_1` for the citation.  A stream this
    /// version writes leaves the caller's quality bytes alone.
    pub const vers_4_0: c_int = 4;

    /// Compresses a block of concatenated quality values.
    ///
    /// `in` holds raw phred scores with no separators; `slice` describes
    /// how they break into records and is required, because upstream's
    /// parameter search dereferences it before it looks at the data
    /// (`fqzcomp_qual.c:417`).  For a single record, pass one length equal
    /// to `in.len` and one zero flag.
    ///
    /// **This call writes to all three of its inputs**, and what survives
    /// differs per input.  It is not a const API in disguise, and the
    /// signature says so:
    ///
    ///   * `slice.len` is clamped so the records sum to `in.len`
    ///     (`fqzcomp_qual.c:790`, `:795`);
    ///   * `slice.flags` has the codec's chosen selector ORed into bit 16
    ///     and up whenever its quality-context heuristic fires (`:589`,
    ///     `:596`) and has them cleared again before a successful return
    ///     (`:1219`-`:1221`);
    ///   * for a `vers_3_1` stream the codec reverses every flagged record
    ///     of `in` before encoding it (`:763` sets `GFLAG_DO_REV`,
    ///     `:1087`-`:1109`) and reverses it back before it returns
    ///     (`:1193`-`:1217`), so a *successful* call leaves `in` exactly
    ///     as it was passed.  A `vers_4_0` stream never touches the
    ///     quality bytes.
    ///
    /// Pass buffers you own.  After a successful call the length array
    /// describes what the codec used, and `in` is unchanged; after a
    /// failure that happens between the two reversals - the record-length
    /// check at `:1120` or a failed `RC_FinishEncode` at `:1186` - the
    /// flagged records are left reversed and the caller has to restore
    /// them.  A failure before the reversal step leaves `in` alone.  That
    /// is why the parameter is `[]u8` and not `[]const u8`: upstream's
    /// `char *in` is non-const for exactly this reason, and the two
    /// outcomes are not distinguishable from the error the call returns.
    ///
    /// `strat` selects the parameter search (0 to `max_strategy`).  The
    /// codec picks its own parameters, so no explicit `fqz_gparams` is
    /// ever supplied; `gp` is passed as NULL.
    ///
    /// Upstream has no caller-buffer form, so the result is a single
    /// malloced block and comes back as an `Owned`.
    pub fn compress(vers: c_int, slice: Slice, in: []u8, strat: c_int) Error!Owned {
        if (slice.num_records == 0) return error.InvalidArgument;
        if (slice.len.len != slice.num_records or slice.flags.len < slice.num_records) {
            return error.InvalidArgument;
        }
        var native = c.fqz_slice{
            .num_records = @intCast(slice.num_records),
            .len = @ptrCast(slice.len.ptr),
            .flags = @ptrCast(slice.flags.ptr),
        };
        var out_size: usize = 0;
        const raw = c.fqz_compress(
            vers,
            &native,
            cStrMut(in),
            // fqz_compress takes a size_t but rejects anything above
            // INT_MAX itself.  Checking here keeps the refusal an
            // error.LengthOverflow like every other entry point, instead
            // of a NULL that looks like a rejected stream.
            @intCast(try narrowInt(in.len)),
            &out_size,
            strat,
            null,
        );
        return owned(raw, out_size);
    }

    /// Decompresses a block, discarding the per-record lengths.  Upstream
    /// allows `lengths` to be NULL, so this is the cheap form when the
    /// caller only wants the concatenated quality bytes.
    pub fn decompress(compressed: []const u8) Error!Owned {
        var out_size: usize = 0;
        return owned(
            c.fqz_decompress(cStr(compressed), compressed.len, &out_size, null, 0),
            out_size,
        );
    }

    /// Decompresses a block and fills `lengths` with the record lengths.
    /// `lengths` must have room for every record in the block; upstream
    /// writes into it without a bound of its own.
    pub fn decompressLengths(compressed: []const u8, lengths: []c_int) Error!Owned {
        if (lengths.len == 0) return error.BufferTooSmall;
        var out_size: usize = 0;
        return owned(
            c.fqz_decompress(
                cStr(compressed),
                compressed.len,
                &out_size,
                cIntBuf(lengths),
                try narrowInt(lengths.len),
            ),
            out_size,
        );
    }
};

// ---------------------------------------------------------------------------
// Run length encoding  (rle.c)
// ---------------------------------------------------------------------------

/// The run-length codec.  Upstream's encoder always emits a run length for
/// every symbol listed in `Symbols` and never for any other symbol, so the
/// symbol set is part of the stream contract rather than a detail.
pub const rle = struct {
    /// The symbol set used to encode.  A `count` of 0 on entry asks the
    /// encoder to survey the data and fill both fields in.
    pub const Symbols = struct {
        syms: [256]u8 = @splat(0),
        count: c_int = 0,
    };

    /// What the encoder wrote: the used portion of each buffer.
    pub const Encoded = struct {
        out_len: usize,
        run_len: usize,
    };

    /// Encodes `data`.  `run` and `out` must each hold at least `data.len`
    /// bytes, and a shorter one is `error.BufferTooSmall`: upstream writes
    /// one literal per input byte into `out` (`rle.c:122`) and one varint
    /// per run into `run` through an unbounded `var_put_u32` (`rle.c:131`),
    /// checking neither.  A run of length L costs at most L varint bytes,
    /// so `data.len` is the true bound for both.  (Upstream's own
    /// allocating path asks for `2 * data.len`; that is generous, not
    /// required.)  Neither may overlap `data`.  `syms` is updated in place
    /// with the symbol set actually used; pass it to `decode` to read the
    /// stream back.
    pub fn encode(data: []const u8, run: []u8, syms: *Symbols, out: []u8) Error!Encoded {
        try checkDisjoint(data, run);
        try checkDisjoint(data, out);
        if (run.len < data.len or out.len < data.len) return error.BufferTooSmall;
        var run_len: u64 = 0;
        var out_len: u64 = 0;
        const raw = c.hts_rle_encode(
            cPtr(data),
            data.len,
            cOutBuf(run),
            &run_len,
            cMap(syms.syms[0..]),
            &syms.count,
            cOutBuf(out),
            &out_len,
        );
        if (cIsNull(raw)) return error.OperationFailed;
        return .{ .out_len = @intCast(out_len), .run_len = @intCast(run_len) };
    }

    /// Expands a run-length stream into `out` and returns the bytes used.
    /// `lit` and `run` are the two halves produced by `encode`; neither
    /// may overlap `out`.
    pub fn decode(lit: []const u8, run: []const u8, syms: *const Symbols, out: []u8) Error!usize {
        try checkDisjoint(lit, out);
        try checkDisjoint(run, out);
        var out_len: u64 = out.len;
        const raw = c.hts_rle_decode(
            cPtr(lit),
            lit.len,
            cPtr(run),
            run.len,
            cMap(syms.syms[0..]),
            syms.count,
            cOutBuf(out),
            &out_len,
        );
        if (cIsNull(raw)) return error.OperationFailed;
        return @intCast(out_len);
    }
};

// ---------------------------------------------------------------------------
// Read-name tokeniser  (tokenise_name3.c)
// ---------------------------------------------------------------------------

/// The read-name tokeniser used by CRAM for name blocks.
pub const tok3 = struct {
    /// Compresses a block of `\n`-separated or `\0`-separated read names.
    ///
    /// `level` is 1 to 19.  Upstream's own test driver treats levels of 11
    /// and above as "use the arithmetic coder internally"; pass
    /// `use_arith = false` to let it decide, or true to force the flag on.
    ///
    /// **The block is destroyed as it is encoded.**  Upstream replaces
    /// every `\n` or `\0` separator with `\0` in place
    /// (`tokenise_name3.c:1500`), which is why the parameter is `[]u8` and
    /// not `[]const u8` — the `char *` in upstream's prototype is
    /// non-const for exactly this reason.  Pass a copy if you still need
    /// the names, and never pass a string literal or other read-only
    /// memory.
    ///
    /// Upstream can only encode whole lines.  When `last_start` is non-NULL
    /// it receives the offset of the first byte of the trailing partial
    /// line, so a caller streaming large files can carry the remainder
    /// into the next block.
    pub fn encodeNames(
        block: []u8,
        level: c_int,
        use_arith: bool,
        last_start: ?*c_int,
    ) Error!Owned {
        var out_len: c_int = 0;
        return owned(
            c.tok3_encode_names(
                cStrMut(block),
                try narrowInt(block.len),
                level,
                @intFromBool(use_arith),
                &out_len,
                last_start,
            ),
            @intCast(out_len),
        );
    }

    /// Decodes a block written by `encodeNames`, returning the names
    /// separated by NUL bytes.  Upstream rejects inputs shorter than 9
    /// bytes.
    pub fn decodeNames(compressed: []const u8) Error!Owned {
        if (compressed.len > std.math.maxInt(u32)) return error.LengthOverflow;
        var out_len: u32 = 0;
        return owned(
            c.tok3_decode_names(cPtr(compressed), @intCast(compressed.len), &out_len),
            out_len,
        );
    }
};

// ---------------------------------------------------------------------------
// Symbol bit packing  (pack.c)
// ---------------------------------------------------------------------------

/// The bit-packing helper the arithmetic coder's X_PACK method is built on.
pub const pack = struct {
    /// The map written by `packData` and read by `unpackMeta`.
    pub const Meta = struct {
        /// Code 0 is the count of used symbols; codes 1..n are the symbols.
        ///
        /// 257 bytes, not 256.  `hts_pack` walks the input assigning each
        /// used symbol the next code and writing `out_meta[n] = i`
        /// *before* it checks whether the alphabet is narrow enough
        /// (`pack.c:68` writes the code, `pack.c:75` rejects the width).
        /// write lands on index 256, one past a 256-byte buffer, and the
        /// rejection comes afterwards.  The spare byte is the fix.
        map: [257]u8 = @splat(0),
        meta_len: c_int = 0,
    };

    /// Packs `data` when it uses at most 16 distinct symbols, and fills
    /// `meta` with the map needed to reverse it.
    ///
    /// Returns `error.OperationFailed` when the data uses more than 16
    /// symbols, which upstream rejects after filling the map.
    /// That fill happens before the width check, so `meta` is
    /// meaningless when this returns an error — the map may hold 256
    /// symbols even though the call failed.
    pub fn packData(data: []const u8, meta: *Meta) Error!Owned {
        var out_len: u64 = 0;
        return owned(
            c.hts_pack(
                cPtr(data),
                try narrowInt(data.len),
                cMap(meta.map[0..]),
                &meta.meta_len,
                &out_len,
            ),
            @intCast(out_len),
        );
    }

    /// Reads the map at the front of a packed stream.  `map` receives the
    /// used symbols and `nsym` the symbols per byte (0, 1, 2, 4 or 8).
    /// Returns the number of header bytes consumed.  `map` must be at
    /// least 256 bytes.
    pub fn unpackMeta(data: []const u8, udata_len: u64, map: []u8) Error!struct { consumed: usize, nsym: c_int } {
        if (map.len < min_map_len) return error.InvalidArgument;
        if (data.len > std.math.maxInt(u32)) return error.LengthOverflow;
        var nsym: c_int = 0;
        const used = c.hts_unpack_meta(cPtr(data), @intCast(data.len), udata_len, cMap(map), &nsym);
        if (used == 0) return error.OperationFailed;
        return .{ .consumed = used, .nsym = nsym };
    }

    /// Expands a packed stream into `out` using the map and symbol count
    /// from `unpackMeta`.  `out` must be the exact unpacked size, and
    /// `map` at least 256 bytes.
    ///
    /// The returned length is what upstream actually wrote, which is not
    /// always `out.len`: `nsym == 1` means "not packed at all", which
    /// `unpackMeta` returns for an alphabet wider than 16 symbols, and that
    /// path copies `data.len` bytes (`pack.c:212-215`) into a destination
    /// upstream never compares against `out_len`.  So the check below
    /// refuses the destination that copy would overrun, and the returned
    /// length is `data.len` rather than the buffer's size, because the
    /// bytes past it were never written.
    pub fn unpackTo(data: []const u8, out: []u8, nsym: c_int, map: []const u8) Error!usize {
        if (map.len < min_map_len) return error.InvalidArgument;
        try checkDisjoint(data, out);
        if (nsym == 1 and data.len > out.len) return error.BufferTooSmall;
        const raw = c.hts_unpack(
            cPtr(data),
            try narrowInt(data.len),
            cOutBuf(out),
            out.len,
            nsym,
            cMap(map),
        );
        if (cIsNull(raw)) return error.OperationFailed;
        if (nsym == 1) return data.len;
        return out.len;
    }
};
