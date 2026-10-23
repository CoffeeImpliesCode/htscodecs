// SPDX-License-Identifier: BSD-3-Clause
//! Idiomatic Zig facade over the upstream htscodecs C library.
//!
//! This file adds no algorithms.  Every function is a thin, audited wrapper
//! around the matching entry point in the `c` module (the translation of
//! include/htscodecs_all.h), and the raw C surface stays reachable through
//! `htscodecs.c` for anything the facade does not cover.
//!
//! ## The shortest useful sequence
//!
//! Compress into a buffer you own, size the decode destination exactly,
//! and release whatever upstream allocated.
//!
//! ```zig
//! const htscodecs = @import("htscodecs");
//!
//! const phrase = "the quick brown fox jumps over the lazy dog";
//! const twice = phrase ++ phrase;
//! const payload = twice ++ twice ++ twice ++ twice;
//!
//! // Caller buffers.  Nothing is allocated by the library on this path.
//! const bound = try htscodecs.rans4x16.compressBound(payload.len, 0);
//! const scratch = try allocator.alloc(u8, bound);
//! defer allocator.free(scratch);
//! const n = try htscodecs.rans4x16.compressTo(payload, scratch, 0);
//!
//! // Size the decode destination to the payload, not to a round number.
//! // A STRIPE stream is rejected outright if the destination is *larger*
//! // than the original, not merely if it is smaller.
//! const plain = try allocator.alloc(u8, payload.len);
//! defer allocator.free(plain);
//! const m = try htscodecs.rans4x16.uncompressTo(scratch[0..n], plain);
//! assert(std.mem.eql(u8, plain[0..m], payload));
//!
//! // Where upstream has no caller-buffer form the result is an `Owned`:
//! // one malloced block, one `deinit`, and never both a copy of the
//! // handle and its original released.
//! const packed = try htscodecs.rans4x8.compress(payload, 0);
//! defer packed.deinit();   // std.c.free, the allocator that produced it
//! use packed.slice();
//! ```
//!
//! Three rules shape the wrappers:
//!
//! 1. Ownership is explicit.  Where upstream has a `*_to` entry point that
//!    writes into a caller buffer, the wrapper writes into yours and returns
//!    the used length; nothing is allocated.  Where upstream only offers a
//!    `malloc`ing entry point, the wrapper returns an `Owned` that wraps the
//!    C pointer and frees it with the C allocator in `deinit`.  No Zig
//!    allocator is involved and no process-global hook is installed.
//! 2. A length upstream's own prototype would truncate is refused with
//!    `error.LengthOverflow` before the call.  Upstream is inconsistent
//!    here: some entry points take `unsigned int` or `int` and reject
//!    anything above `INT_MAX`, others take `uint64_t`, where a `usize`
//!    length widens and cannot lose a value.  A wrapper narrows only where
//!    narrowing can happen.
//! 3. Aliasing is refused exactly where upstream reads one region while
//!    writing another.  Each wrapper names the pair it checks; a wrapper
//!    with a single caller buffer has nothing to check.  The check is an
//!    ordinary comparison, so the refusal is a published error in every
//!    build mode rather than a debug assertion a release build drops.
//!
//! Upstream reports failure as a NULL return, and does not distinguish
//! "the stream is invalid" from "allocation failed" (or, for the encoding
//! side, from "your buffer is too small").  The wrappers cannot recover
//! information upstream threw away, so they map NULL as documented on each
//! function rather than inventing a distinction.
//!
//! ## Two configurations, one typed surface
//!
//! Everything above is written once against the `c` module, and `c` is
//! either the translated header or a generated dispatch that resolves the
//! same names through a table.  In a linked build every call below is a
//! direct call with no table and no readiness check.  In a runtime-loading
//! build (`-Druntime=true`) the same calls go through the table that
//! `htscodecs.load` fills, and a call before a successful load stops the
//! program naming the function.  `htscodecs.runtime_loaded` says which
//! configuration this build is, at comptime.
//!
//! Two consequences are worth knowing before using the runtime route:
//!
//!   * `Owned` is still freed with the C allocator in both configurations.
//!     Upstream's `malloc`-ing entry points allocate with libc `malloc`
//!     (`rANS_static.c:77`, `rANS_static4x16pr.c:1040`), not with
//!     `htscodecs_tls_alloc`, so `std.c.free` is the pairing - and it stays
//!     the pairing for a provider loaded into this process.
//!   * `tls` below is the library's *own* pool, a different family with a
//!     different pairing: what `tls.alloc` returns is released with
//!     `tls.free`, never with libc `free`.  Use it for scratch memory you
//!     want the provider to hold; use `Owned` for a compressed result.

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
    /// A caller length does not fit the narrower type upstream's prototype
    /// takes for it, so passing it on would truncate or wrap.  Upstream's
    /// own entry points refuse the same inputs
    /// (`rANS_static4x16pr.c:1206`, `arith_dynamic.c:736`,
    /// `rANS_static.c:831`, `fqzcomp_qual.c:1617`), so naming the bound here
    /// keeps the outcome a length problem rather than an unexplained NULL.
    /// Only the wrappers that actually narrow raise it; where the C
    /// parameter is `uint64_t` a `usize` length widens and there is nothing
    /// to lose.  A count is a length here too: `Slice.num_records` reaches
    /// upstream as an `int`, so it is refused above `max_stream_len`
    /// rather than truncated.
    LengthOverflow,

    /// The facade rejected the argument itself, before calling upstream:
    /// an order byte the chosen kernel does not implement, a negative
    /// fqzcomp strategy, a record array whose length contradicts
    /// `Slice.num_records`, a symbol map shorter than the 256 bytes the C
    /// code reads and writes, an `rle.Symbols`
    /// count outside the 256-entry array, or the input/output pair a
    /// particular wrapper names as unsafe to overlap.  Fixing the argument
    /// is the whole remedy; nothing upstream ran.
    InvalidArgument,

    /// The facade compared two lengths the caller supplied and knows the
    /// destination cannot hold the result: a zero-length destination, a
    /// `rle.encode` whose `run` or `out` is smaller than the size that
    /// call documents as required, an `fqzcomp.decompressLengths` with no
    /// room at all for the record lengths, or a stream that
    /// `pack.unpackTo` would copy past its destination.  This is the only
    /// error a caller can act on by resizing and retrying.
    BufferTooSmall,

    /// Upstream returned NULL, and the C API does not say why.  Depending
    /// on the call, that may mean the stream was malformed, the capacity
    /// was insufficient, the method is compiled out (the arithmetic
    /// coder's `ext` without `-Dbz2=true`), or an allocation failed.  None
    /// of those is distinguishable from the others through `htscodecs.c`,
    /// so this says only what is true: the operation did not succeed.
    /// Nothing about the cause can be recovered from it, and the out
    /// parameters the C function had already written are not reported
    /// either - read the doc on the function for what its own NULL leaves
    /// behind.
    OperationFailed,

    /// The library's own thread-local pool returned NULL for this request.
    ///
    /// The one error here that names its own cause rather than reporting a
    /// NULL whose reason upstream threw away: `htscodecs_tls_alloc` and
    /// `htscodecs_tls_calloc` do nothing but allocate
    /// (`htscodecs/utils.c:119`-`:181`), so a NULL from either means the
    /// pool had nothing to give.
    AllocationFailed,
};

/// The ceiling this facade uses wherever it has to narrow a caller length
/// to upstream's `unsigned int` or `int`: `INT_MAX`, above which those
/// parameters would be rejected or would wrap.  Upstream's encoders test
/// the same bound themselves, so refusing here keeps the outcome a length
/// problem instead of an unexplained NULL.
///
/// It is *not* a limit on every buffer in the library.  `rle.encode` and
/// `rle.decode` hand upstream `uint64_t` lengths that a `usize` widens
/// into without loss (`rle.c:100`-`:103`, `:142`-`:145`), and
/// `pack.unpackMeta` accepts up to `std.math.maxInt(u32)`.  Each wrapper
/// documents what it accepts, and a wrapper that narrows one length and
/// not another says which is which.
pub const max_stream_len: usize = std.math.maxInt(c_int);

// ---------------------------------------------------------------------------
// Owned results
// ---------------------------------------------------------------------------

/// A buffer upstream allocated with `malloc`, owned by the caller.
///
/// This is a single-owner handle to one block, and it is the only thing the
/// facade hands back that has to be released.  `slice` is a window on that
/// block and `deinit` frees it, so there is no second thing to free and no
/// Zig allocator anywhere in the path.
///
/// * **Valid state.**  Only the functions that return an `Owned` can produce
///   a meaningful one.  `ptr` and `len` are reachable and mutable and the
///   facade does not police them: a `len` wider than the block turns
///   `slice` into an out-of-bounds read, and a `ptr` from somewhere else
///   turns `deinit` into the wrong free.
/// * **One owner, one release.**  An `Owned` owns its block outright.
///   Copying the struct copies the pointer and the length and nothing else,
///   so both copies refer to the same allocation and `deinit` on either
///   frees it.  Release it exactly once, on one copy, and never on a second
///   copy of the same value - that is a double free.  `deinit` is not
///   idempotent and nothing here makes it so.
/// * **Move it, do not share it.**  To hand an `Owned` on, pass the value
///   and stop using your own copy.  `deinit` takes `self` by value, which
///   is what makes `defer encoded.deinit()` correct: the caller's own
///   variable is still there afterwards and its pointer dangles.
/// * **Releaser.**  `std.c.free`, the correct pairing for upstream's
///   `malloc`.  No Zig allocator is involved and no process-global
///   allocator hook is installed, so `std.testing.allocator` cannot see
///   these bytes: a leak oracle over Zig allocations does not cover them.
///   An `Owned` may be produced in one context and released in another.
/// * **What `len` means.**  The length upstream reported as used.  The
///   allocation may be larger; the bytes past `len` are not part of the
///   result.
pub const Owned = struct {
    /// Start of the malloced block.  Owned by this value; see the type doc
    /// before overwriting it.
    ptr: [*]u8,

    /// How many bytes are the result.  This is not the size of the block.
    len: usize,

    /// The owned bytes, valid until `deinit`.  A window, not a copy: it
    /// aliases the block, so writes through it change the owned bytes, and
    /// it dangles the moment `deinit` runs.  Do not retain it past the
    /// release.
    pub fn slice(self: Owned) []u8 {
        return self.ptr[0..self.len];
    }

    /// Releases the block with the C allocator that produced it, and
    /// leaves the caller's copy of `self` pointing at freed memory.  Call
    /// this once; calling it again on the same value, or on any copy of
    /// it, is a double free.
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

// ---------------------------------------------------------------------------
// The library's own allocation pool  (utils.c)
// ---------------------------------------------------------------------------

/// `htscodecs`'s thread-local allocation pool, exported from `utils.c` and
/// declared by `utils.h:63`-`:65`.
///
/// **This is a different family from `Owned` and the pairing is not
/// interchangeable.**  What `alloc` and `calloc` return is released with
/// `free` *here* - `htscodecs_tls_free` - and never with libc `free`; and
/// what libc `free` receives, from `Owned.deinit`, must never be passed to
/// this.  Upstream keeps the two apart: the compressing entry points
/// allocate with plain `malloc` (`rANS_static.c:77`,
/// `rANS_static4x16pr.c:1040`, `arith_dynamic.c:100`), while this pool is
/// what the frequency tables and per-record scratch come from
/// (`fqzcomp_qual.c:323`, `utils.h:146`).
///
/// What the pool is depends on how the library was built.  With threads
/// (`utils.c:119`-`:208`) it keeps a small per-thread cache behind a
/// `pthread_key`. Allocate and free each pointer on the same thread: freeing
/// on another thread that has no pool dereferences null in upstream, and a
/// different pool cannot reclaim the allocation. Without threads -
/// `include/htscodecs_config.h:99`-`:103` sets `NO_THREADS` for `__wasi__` -
/// the three functions are plain `calloc`/`free` (`utils.c:223`-`:233`).
/// Nothing here allocates from a Zig allocator or installs a process-global hook,
/// so `std.testing.allocator` cannot see these bytes: a leak oracle over
/// Zig allocations does not cover them.
pub const tls = struct {
    /// `size` bytes from the pool, or `error.AllocationFailed`.
    ///
    /// Contents are unspecified. Fresh allocations are zeroed, but the
    /// threaded reuse path returns the previous contents (`utils.c:141-162`).
    pub fn alloc(size: usize) Error![*]u8 {
        return tlsBlock(c.htscodecs_tls_alloc(size));
    }

    /// `nmemb * size` zeroed bytes from the pool, or
    /// `error.AllocationFailed`.
    ///
    /// Caller precondition: `nmemb * size` fits in `usize`. The C library
    /// multiplies without an overflow check (`utils.c:173-181`); this thin
    /// wrapper does not turn a wrapped product into an allocation failure.
    pub fn calloc(nmemb: usize, size: usize) Error![*]u8 {
        return tlsBlock(c.htscodecs_tls_calloc(nmemb, size));
    }

    /// Releases a pointer from `alloc` or `calloc`.  Null is accepted and
    /// does nothing, which is upstream's own behaviour.
    /// In a threaded build, call on the same thread that allocated it.
    ///
    /// This is not `cFree`.  A pointer from `Owned.deinit` must go to libc
    /// `free` and must never reach here.
    pub fn free(ptr: ?[*]u8) void {
        c.htscodecs_tls_free(@ptrCast(ptr));
    }

    fn tlsBlock(raw: ?*anyopaque) Error![*]u8 {
        const block = raw orelse return error.AllocationFailed;
        return @ptrCast(block);
    }
};

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

/// The number of entries in `rle.Symbols.syms`, and so the largest symbol
/// count either rle direction accepts.  Upstream indexes that array with
/// the caller's own count and no bound of its own - `rle.c:112-114`
/// encodes, `rle.c:155-156` decodes - so anything outside 0..256 is a
/// facade question, not one to hand to C.  Same value as `min_map_len`,
/// different meaning: this one bounds a count, that one a length.
const max_rle_symbols = 256;

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

/// The aliasing guard for a `[]u8` destination.  Upstream reads one region
/// while writing another, so overlapping buffers make the result depend on
/// the order the C code happens to touch the bytes.  This is an ordinary
/// comparison that returns `error.InvalidArgument` before the call in
/// every build mode, ReleaseFast and ReleaseSmall included, because the
/// public contract is that error and not a debug assertion: a guard that
/// vanishes in a release build would document a promise the library stops
/// keeping exactly where a caller is least able to notice.
///
/// It is used only where the read and the write really do reach the same
/// call.  Each wrapper that calls it says which pair it refuses; two
/// read-only buffers that merely happen to be adjacent, or that the caller
/// is free to share, are not its business.
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
    /// returns the number of bytes written.  The overlap refusal is an
    /// ordinary comparison that runs before the call in every build mode.
    ///
    /// For a stream carrying the `stripe` order bit the destination must be
    /// exactly the original size.  `rANS_static4x16pr.c:1619` compares the
    /// length it read from the stream against the capacity for *equality*
    /// (`if (ulen != *out_size) return NULL;`), so an over-sized buffer is
    /// rejected exactly as a short one is and surfaces as
    /// `error.OperationFailed`.  Every other order accepts a larger
    /// destination.
    ///
    /// In the non-stripe path a short destination is reported the same way:
    /// upstream returns NULL without writing the size it needed, so the two
    /// cases cannot be told apart.  A destination of exactly
    /// `max_stream_len` bytes is refused by upstream itself
    /// (`rANS_static4x16pr.c:218`), so the practical ceiling is one byte
    /// below it.
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
    ///
    /// `order` is 0 or 1, as on `compressTo`.  The two lengths are bounded
    /// before the call, and the bounds are not the same.  `compressed.len`
    /// reaches upstream as its `unsigned int in_size`, so a slice longer
    /// than `max_stream_len` is `error.LengthOverflow`; a slice of exactly
    /// `max_stream_len` is passed on.  `out` does not: upstream takes the
    /// caller's capacity directly (`unsigned int out_sz`) and refuses
    /// `out_sz >= INT_MAX` itself (`rANS_static32x16pr.c:261` for order 0,
    /// `:534` for order 1), so the facade names the ceiling
    /// `error.LengthOverflow` rather than forwarding a call that can only
    /// come back NULL.  A destination of exactly `max_stream_len` bytes is
    /// refused before the call, and the practical ceiling is one byte below
    /// it.  A destination of zero bytes is `error.BufferTooSmall`.
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
    /// returns the number of bytes written.  The overlap refusal is an
    /// ordinary comparison that runs before the call in every build mode.
    ///
    /// For a stream carrying the `stripe` order bit the destination must be
    /// exactly the original size: `arith_dynamic.c:1063` compares the length
    /// it read from the stream against the capacity for equality
    /// (`if (ulen != *out_size) return NULL;`), so an over-sized buffer is
    /// rejected just as a short one is, and the answer is
    /// `error.OperationFailed`.  For every other order a larger destination
    /// is fine.
    ///
    /// The non-stripe path reports a short destination the same way -
    /// `arith_dynamic.c:1153` returns NULL without writing the size it
    /// needed - and refuses a destination of exactly `max_stream_len` bytes
    /// at `:1136`, so the practical ceiling is one byte below it.
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
/// `fqzcomp.compress` borrows these arrays and never takes ownership:
/// nothing here is freed by the facade and both must outlive the call.
/// They are borrowed *mutably* because the codec writes to them.  It
/// clamps `len` so the records sum to the input length
/// (`fqzcomp_qual.c:790`, `:795`) and ORs its chosen selector into `flags`
/// (`:589`, `:596`); before a successful `fqzcomp.compress` returns it
/// clears those borrowed bits again (`:1219`-`:1221`).  So after a
/// successful call `len` holds the clamped lengths and `flags` holds the
/// bits the caller passed, which is what the codec actually used.
///
/// * **Valid state.**  `num_records` must be 1 or more, `len` exactly
///   `num_records` long and `flags` at least that long; anything else is
///   `error.InvalidArgument`, because upstream indexes both arrays by
///   `num_records` with no bound of its own (`fqzcomp_qual.c:587`, `:417`).
/// * **No overlap guard.**  Nothing compares these arrays against `in` or
///   against each other.  Give each one its own storage.
pub const Slice = struct {
    /// How many records `len` and `flags` describe.  Upstream's field is an
    /// `int`, so a `usize` above `max_stream_len` is refused rather than
    /// truncated.
    num_records: usize,

    /// Quality-string length per record.  Borrowed, and mutated in place.
    len: []u32,

    /// Per-record flags.  Borrowed, and mutated in place.  Upstream reads
    /// only the first `num_records` entries, so a longer array is fine.
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
    /// Upstream's advertised maximum preset, not its strategy-table bound.
    pub const max_strategy: c_int = c.FQZ_MAX_STRAT;
    /// The CRAM version whose streams store qualities in the opposite
    /// orientation, so the encoder reverses each flagged record before
    /// encoding it and the decoder reverses it back: upstream gates that
    /// on `vers == 3` (`fqzcomp_qual.c:763`) and names the two values
    /// "CRAM version 4.0 (4) or 3.1 (3)" in its own test driver
    /// (`tests/fqzcomp_qual_test.c:322`).
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
    /// `strat` selects the parameter search.  Upstream advertises presets
    /// 0 to `max_strategy`, but its table also has a custom row at 4 and
    /// clamps larger indices to that row (`fqzcomp_qual.c:195-203`, `:751`).
    /// A negative index is refused with `error.InvalidArgument` before
    /// the native call; nonnegative indices retain the native upper clamp.
    /// The codec picks its own parameters, so no explicit `fqz_gparams`
    /// is ever supplied; `gp` is passed as NULL.
    ///
    /// Upstream has no caller-buffer form, so the result is a single
    /// malloced block and comes back as an `Owned`.
    ///
    /// No overlap guard runs here.  Upstream reads `slice.len` and
    /// `slice.flags` while it writes them, and reverses `in` in place, so
    /// give each buffer its own storage: unlike the `*_to` wrappers this one
    /// does not compare them for you.
    pub fn compress(vers: c_int, slice: Slice, in: []u8, strat: c_int) Error!Owned {
        if (strat < 0) return error.InvalidArgument;
        if (slice.num_records == 0) return error.InvalidArgument;
        if (slice.len.len != slice.num_records or slice.flags.len < slice.num_records) {
            return error.InvalidArgument;
        }
        var native = c.fqz_slice{
            // Upstream's field is an `int`; checked rather than cast, so
            // a record count above INT_MAX is error.LengthOverflow like
            // every other length boundary here instead of a wrap.
            .num_records = try narrowInt(slice.num_records),
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
    ///
    /// `lengths` must not overlap `compressed`: upstream reads the block
    /// while it writes one `int` per decoded record
    /// (`fqzcomp_qual.c:1419`-`:1420`), and the facade compares the two
    /// before the call in every build mode.
    ///
    /// **`lengths.len` is the bound upstream is given**, not a
    /// requirement: `fqz_decompress` receives it as `nlengths` and writes
    /// `lengths[rec]` only while `rec < nlengths`
    /// (`fqzcomp_qual.c:1419`).  A block with more records than the array
    /// holds therefore decodes successfully, with the tail records' lengths
    /// simply absent - no error, no overflow.  Size the array from the
    /// record count you expect if you need every one of them.
    ///
    /// The entries are filled in as records are decoded, so a call that
    /// returns `error.OperationFailed` partway through leaves the lengths
    /// it had already written in place.  Nothing distinguishes them from
    /// the caller's own prior contents.
    ///
    /// A zero-length array is `error.BufferTooSmall` before the call.
    pub fn decompressLengths(compressed: []const u8, lengths: []c_int) Error!Owned {
        if (lengths.len == 0) return error.BufferTooSmall;
        try checkDisjoint(compressed, std.mem.sliceAsBytes(lengths));
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

    /// Analyses a quality block and fills a parameter block and a symbol
    /// histogram, which is what a caller needs before it can hand its own
    /// `fqz_gparams` to `fqz_compress`.  Upstream uses this from its own
    /// parameter-tuning path and calls it a utility
    /// (`fqzcomp_qual.h:169`-`:172`); `fqzcomp.compress` never needs it
    /// because it picks its own parameters.
    ///
    /// **`slice.flags` is written.**  This call ORs a selector value into
    /// bits 16 and up of every entry when its heuristic fires
    /// (`fqzcomp_qual.c:588` and `:597`), the same borrowed-mutably
    /// arrangement `compress` has and for the same reason; what survives a
    /// successful call is the selector the analysis chose.  `slice.len` is
    /// only read.  Both arrays must be **one entry longer than
    /// `num_records`**: upstream's selector-filter checks read
    /// `slice.flags[rec]` before checking `rec < num_records`
    /// (`fqzcomp_qual.c:434`, `:533`), and their skip paths also read
    /// `slice.len[rec]` (`:436`, `:534`).  A block whose record lengths do
    /// not exactly consume `in` can reach that extra entry.  The facade
    /// refuses a shorter pair with `error.InvalidArgument` in every build
    /// mode rather than leaving those reads to the caller's arrays.
    /// Supply the extra entry for those native paths; the facade passes
    /// its contents through unchanged.
    /// Record-count narrowing precedes that capacity comparison, so a
    /// count above `max_stream_len` returns `error.LengthOverflow`
    /// without adding the extra entry to an unrepresentable count.
    ///
    /// `in` is read and never written, so a `[]const u8` is honest here even
    /// though `compress` needs a mutable one.
    ///
    /// `params` is the caller's `fqz_param`, taken by pointer and both read
    /// and written: upstream reads `params.do_qa` at `fqzcomp_qual.c:481` to
    /// decide whether to tune the selector histogram, and then sets
    /// `do_dedup` (`:468`), `max_sym` and `nsym` (`:473`-`:477`) among others.
    /// So it has to be initialised before the call - an all-zero block is a
    /// valid one - and what it holds afterwards is what upstream computed.
    ///
    /// `histogram` receives 256 `u32` counts, one per quality value.  It is
    /// not cleared first, so it has to start zeroed if the total is to mean
    /// anything.
    ///
    /// Upstream allocates internally and returns `void`
    /// (`fqzcomp_qual.c:433`-`:436`), so an allocation failure is a silent
    /// early return that happens before the first write: `histogram`,
    /// `params` and `slice` are then exactly as the caller left them.  That
    /// is why this call reports no error and why a caller cannot tell the
    /// two apart; nothing the facade could return would be honest.
    ///
    /// `one_param` selects one selector value from `slice.flags` bits 16 and
    /// up; -1 analyses every record, which is what upstream's own caller
    /// passes.
    pub fn qualStats(
        slice: Slice,
        in: []const u8,
        params: *c.fqz_param,
        histogram: *[256]u32,
        one_param: c_int,
    ) Error!void {
        if (slice.num_records == 0) return error.InvalidArgument;
        const num_records = try narrowInt(slice.num_records);
        if (slice.len.len < slice.num_records + 1 or slice.flags.len < slice.num_records + 1) {
            return error.InvalidArgument;
        }
        var native = c.fqz_slice{
            .num_records = num_records,
            .len = @ptrCast(slice.len.ptr),
            .flags = @ptrCast(slice.flags.ptr),
        };
        c.fqz_qual_stats(&native, cPtr(in), in.len, params, histogram, one_param);
    }
};

// ---------------------------------------------------------------------------
// Run length encoding  (rle.c)
// ---------------------------------------------------------------------------

/// The run-length codec.  Upstream's encoder always emits a run length for
/// every symbol listed in `Symbols` and never for any other symbol, so the
/// symbol set is part of the stream contract rather than a detail.
pub const rle = struct {
    /// The symbol set, which is part of the stream rather than a detail:
    /// a decoder cannot read a run-length block without the set the
    /// encoder used.
    ///
    /// `count` must be 0..256 on both sides.  0 on entry to `encode` is not
    /// "no symbols": it asks the encoder to survey the data and fill both
    /// fields in (`rle.c:115-118`), and `decode` needs the answer that
    /// survey produced to read the stream back.  Anything outside that
    /// range is `error.InvalidArgument`, refused before the C call in every
    /// build mode, because upstream indexes `syms` with this count and
    /// checks nothing (`rle.c:112-114`, `:155-156`).
    ///
    /// `encode` takes this by pointer and writes it: after a call it holds
    /// the symbol set actually used.  `decode` takes it `*const` and only
    /// reads it.
    pub const Symbols = struct {
        /// The symbols, `count` of them in use.  Upstream reads
        /// `syms[0..count]`.
        syms: [256]u8 = @splat(0),

        /// How many entries of `syms` are live, 0..256.
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
    /// required.)  Neither `run` nor `out` may overlap `data`; that pair is
    /// the one the facade compares, before the call and in every build
    /// mode.  It does not compare `run` against `out`, so give the two
    /// destinations their own storage - upstream writes both in the same
    /// loop (`rle.c:122`-`:131`).  `syms` is updated in place with the
    /// symbol set actually used; pass it to `decode` to read the stream
    /// back.
    ///
    /// Upstream's only NULL return on this path is its own allocation
    /// failure (`rle.c:105`-`:107`), which the facade cannot reach because it
    /// always supplies `out`.  `error.OperationFailed` here has no cause a
    /// caller could act on.
    pub fn encode(data: []const u8, run: []u8, syms: *Symbols, out: []u8) Error!Encoded {
        // Before the aliasing and size checks: the count is a property of
        // `syms` alone, so refusing it first means an out-of-range count
        // never gets as far as comparing the caller's buffers.
        if (syms.count < 0 or syms.count > max_rle_symbols) return error.InvalidArgument;
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
    /// `lit` and `run` are the two halves produced by `encode`; neither may
    /// overlap `out`, and each of those two pairs is compared before the
    /// call.  The two inputs are both read-only and are not compared with
    /// each other, so they may share storage.
    ///
    /// **A failed call leaves `out` partly overwritten.**  Upstream decodes
    /// straight into the caller's buffer - one byte per literal
    /// (`rle.c:176`, `:179`), and a whole run at a time through `memset`
    /// (`rle.c:173`) - and takes its error path from two points inside that
    /// loop, each of them before the write it guards (`rle.c:163`-`:164`,
    /// `:171`-`:172`).  What survives an `error.OperationFailed` is then
    /// exactly the prefix the completed iterations wrote: those bytes hold
    /// decoded data, the rest still holds whatever the caller had put
    /// there, and nothing at the call site distinguishes the two.
    ///
    /// The length of that prefix is not recoverable.  Upstream returns NULL
    /// without storing the count it had reached (`rle.c:187`-`:188`), so
    /// `*out_len` still holds the capacity the wrapper seeded it with -
    /// `out.len` - and `error.OperationFailed` carries no length back.  The
    /// wrapper neither clears the destination nor copies anything over it:
    /// zeroing would replace decoded residue with zeros, not restore what
    /// the caller had, and it would destroy the only evidence that a decode
    /// started.  Treat `out` as consumed once the call fails, and decode
    /// into it again only after re-establishing its contents.
    ///
    /// A destination too small to hold the result is that same
    /// `error.OperationFailed`, not a resizable `error.BufferTooSmall`:
    /// upstream compares its own `outp` against the end it derived from
    /// `*out_len` and reports no size it needed.  An empty `out` is refused
    /// at the top of the first iteration with nothing written; an empty
    /// `lit` never enters the loop and succeeds, returning 0.
    pub fn decode(lit: []const u8, run: []const u8, syms: *const Symbols, out: []u8) Error!usize {
        if (syms.count < 0 or syms.count > max_rle_symbols) return error.InvalidArgument;
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
    ///
    /// **A failed call can leave `last_start` holding residue.**  Upstream
    /// writes it exactly once, at `tokenise_name3.c:1482`-`:1483`, once it
    /// has scanned the whole block and built the trie.  A failure before
    /// that point - `create_context` at `:1464`, or `build_trie` at
    /// `:1477` - returns without touching it, so whatever the caller had
    /// there survives; a failure after it leaves upstream's offset there.
    /// The wrapper neither clears nor synthesises it, because it cannot tell
    /// which of the two it is looking at: both arrive as
    /// `error.OperationFailed`.  Treat the value as meaningful only when
    /// the call succeeded.
    ///
    /// The block's own state splits on the same line.  Before `:1483`
    /// nothing has been rewritten; after it, every separator already passed
    /// has become `\0` and the rest may not have, so a failed call can
    /// leave a block that is neither the input nor a decodable stream.
    /// Rebuild it from your own copy before retrying.
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
    /// `data` must not overlap `meta.map`: upstream reads data again after
    /// writing the map (`htscodecs/pack.c:63-70`, `:98-100`). This pair is not
    /// checked by the facade.
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
    /// least 256 bytes, or this is `error.InvalidArgument` before the call.
    ///
    /// `data.len` is narrowed to upstream's `uint32_t` (`pack.h:66`), so a
    /// longer slice is `error.LengthOverflow`.
    ///
    /// Upstream reads `data` while it fills `map`, so the two must be
    /// separate regions.  Nothing here compares them for you.
    pub fn unpackMeta(data: []const u8, udata_len: u64, map: []u8) Error!struct { consumed: usize, nsym: c_int } {
        if (map.len < min_map_len) return error.InvalidArgument;
        if (data.len > std.math.maxInt(u32)) return error.LengthOverflow;
        var nsym: c_int = 0;
        const used = c.hts_unpack_meta(cPtr(data), @intCast(data.len), udata_len, cMap(map), &nsym);
        if (used == 0) return error.OperationFailed;
        return .{ .consumed = used, .nsym = nsym };
    }

    /// Expands a packed stream into `out` using the map and symbol count
    /// from `unpackMeta`.  The caller must supply the exact unpacked size
    /// in `out.len`; packed bits alone do not retain it.  The facade does
    /// not validate that size.  A native NULL, including a packed-input
    /// length rejection, becomes `error.OperationFailed`.  `map` must be
    /// at least 256 bytes or the facade returns `error.InvalidArgument`.
    /// `data` and `out` are compared, and overlapping them is
    /// refused before the call in every build mode.  `map` is not
    /// compared, though upstream reads it while it writes `out`, so keep
    /// it clear of the destination.  Of the two lengths it takes, only
    /// `data.len` is bounded: upstream's parameter is `int64_t len`
    /// (`pack.h:80`), narrowed by the same `narrowInt` the rest of the
    /// facade uses, so a slice longer than `max_stream_len` is
    /// `error.LengthOverflow` before the call.  That ceiling is the
    /// facade's own: `int64_t` could carry four billion times as much, and
    /// the wrapper refuses at the shared `narrowInt` bound regardless.
    /// `out.len` is the other length and reaches upstream as a `uint64_t`,
    /// not narrowed.
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
