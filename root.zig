// SPDX-License-Identifier: BSD-3-Clause
//!
//! htscodecs: the CRAM external-block codecs, packaged for Zig 0.17.
//!
//! This package builds the unmodified upstream C library from source
//! (rANS 4x8, rANS 4x16, the 32x16 SIMD kernels, the dynamic arithmetic
//! coder, fqzcomp quality scores, the read-name tokeniser, run-length
//! coding and symbol packing), translates the complete public C header with
//! `b.addTranslateC`, and adds a small idiomatic facade on top.
//!
//! Two things are published:
//!
//! * `c` - the translated C interface.  Every upstream declaration is
//!   reachable here, so nothing is hidden behind the facade.
//! * The codec namespaces below - `rans4x8`, `rans4x16`, `rans32x16`,
//!   `arith`, `fqzcomp`, `rle`, `tok3`, `pack` and `tls` - which choose the
//!   right upstream entry point, check length narrowing, and make buffer
//!   ownership explicit.
//!
//! ```zig
//! const std = @import("std");
//! const htscodecs = @import("htscodecs");
//!
//! pub fn main(init: std.process.Init) !void {
//!     const phrase = "the quick brown fox jumps over the lazy dog";
//!     const twice = phrase ++ phrase;
//!     const payload = twice ++ twice ++ twice ++ twice;
//!     const bound = try htscodecs.rans4x16.compressBound(payload.len, 0);
//!     const scratch = try init.gpa.alloc(u8, bound);
//!     defer init.gpa.free(scratch);
//!     const n = try htscodecs.rans4x16.compressTo(payload, scratch, 0);
//!     // STRIPE decoding requires the exact original length, not a larger buffer.
//!     const plain = try init.gpa.alloc(u8, payload.len);
//!     defer init.gpa.free(plain);
//!     const m = try htscodecs.rans4x16.uncompressTo(scratch[0..n], plain);
//!     if (!std.mem.eql(u8, plain[0..m], payload)) return error.RoundTripChanged;
//!     std.debug.print("{d} -> {d} -> {d}\n", .{ payload.len, n, m });
//! }
//! ```
//!
//! Where upstream has no caller-buffer form the result is an `Owned`, and
//! that is the only thing here the caller has to release:
//!
//! ```zig
//! const packed = try htscodecs.rans4x8.compress(payload, 0);
//! defer packed.deinit();   // std.c.free, the allocator that produced it
//! use packed.slice();
//! ```
//!
//! `Owned` is a single-owner handle with no copy protection: `deinit` it
//! exactly once, on one copy, never on a copy and its original.
//!
//! ## Two configurations: linked and runtime-loaded
//!
//! This module is built in one of two shapes, and `runtime_loaded` says
//! which at comptime.
//!
//! *Linked* is the default.  The C library is linked, `c` is the
//! translated header, and every call below is a direct call with no table
//! and no check.
//!
//! *Runtime-loaded* is opt-in (`-Druntime=true`).  The library is not
//! linked; `c` is a dispatch generated from the same translation step's
//! output, and every entry point the installed header set declares is
//! resolved through the platform loader when the caller calls
//!
//! ```zig
//! try htscodecs.load(.{ .path = "/usr/lib/libhtscodecs.so" });
//! ```
//!
//! and after that this module is used exactly as if it were linked.  There
//! is no fallback, no automatic retry and no unload: the table is
//! process-global state that other code may already have called through.  A
//! call before a successful `load` stops the program with a message naming
//! the function, in every optimisation mode.
//!
//! `c` names the same types and constants in both configurations -
//! `c.fqz_slice` is the translated header's own struct, not a copy - so a
//! consumer names one type either way.  What differs is how a name reaches
//! the library.  `runtime/library.zig` records what a provider must be for
//! this SDK: the 42 header-declared entry points, the scalar widths and
//! struct layouts they use, the allocator each family pairs with, and the
//! two libbz2 entry points a `-Dbz2=true` provider carries on its own.

const std = @import("std");
const hts = @import("src/htscodecs.zig");

/// The loader core, which is where a linked build's two public types come
/// from.  In a runtime-loading build the dispatch carries its own copy of the
/// same declarations and this module is never resolved, so there is exactly
/// one `LoadSource` and one `LoadError` in a build either way.
const rt = @import("rt");

/// Whether this module was configured to resolve its native symbols at run
/// time.
///
/// False for the ordinary build, where the C library is linked and `c` is
/// the translated header itself.  True when the build generated a dispatch
/// that resolves the same symbols through the platform loader, in which case
/// `load` is the call that makes the library usable.  A comptime constant, so
/// a consumer can write two different code paths and have only the one it
/// chose analysed.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// Which native library `load` should open.
///
/// `.path` is an explicit file path and `.system` is an explicit name for the
/// platform loader.  There is no path-to-system fallback and no implicit
/// fallback of any kind; a request that cannot be honoured is an error, not a
/// different library.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Every way `load` can decline.
///
/// Declared here, in the module a consumer imports, rather than only inside
/// the loader: the caller names the failure it is handling.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Load the native library this module dispatches to.
///
/// In a runtime-loading build this is the whole contract: call it once, then
/// use this module as if it were linked.  Calling it again with the same
/// request succeeds and changes nothing; calling it with a different request
/// after a success is `ProviderMismatch`, and the library already in use stays
/// in use.  A failed attempt publishes nothing and can be retried explicitly,
/// by calling this again: there is no automatic retry, and no implicit
/// second source.
///
/// It keeps the process handle and its own copy of the request to the end of
/// the process.  There is no unload and no reset.
///
/// Safe to call from any thread.  A thread that arrives while an attempt for
/// the same request is in flight waits for that attempt and gets its result,
/// whatever it was.  A call from the thread that is running the attempt is
/// `ReentrantLoad` rather than a deadlock.
///
/// In a linked build there is no provider, no table and nothing to resolve,
/// so this stops the program with a message saying so instead of quietly
/// succeeding.  `runtime_loaded` is false there, so a consumer that supports
/// both configurations can tell the two apart at comptime instead of meeting
/// this at run time.
pub fn load(source: LoadSource) LoadError!void {
    if (comptime !runtime_loaded) {
        std.debug.panic(
            "htscodecs: load was called on a linked build; this module is not " ++
                "runtime-loaded, so there is no library to load. Build with " ++
                "runtime loading configured, or do not call load.",
            .{},
        );
    }
    return c.load(source);
}

/// The request that succeeded, or null when nothing has loaded yet.
///
/// The answer is the loader's own retained copy and stays valid for the life
/// of the process.  Null in a linked build, which has no request.
pub fn loadedSource() ?LoadSource {
    if (comptime !runtime_loaded) return null;
    return c.loadedSource();
}

/// Complete translated C interface for include/htscodecs_all.h.
///
/// A direct call in a linked build; a call through the table `load` fills in a
/// runtime-loading one.  Every type and constant here is the translation
/// step's own, so `c.fqz_slice` and the facade's `Slice` fields are one type
/// and no cast crosses a module boundary.
pub const c = hts.c;

/// Failures reported by the facade.
pub const Error = hts.Error;

/// A buffer upstream allocated with `malloc`; free it with `deinit`.
///
/// A single-owner handle with no copy protection: `deinit` exactly once,
/// on one copy.  The full contract - valid state, the copy hazard, the
/// releaser and what `slice` is a view of - is on the defining
/// declaration in `src/htscodecs.zig`.
pub const Owned = hts.Owned;

/// Frees a pointer from one of upstream's `malloc`-ing entry points.
pub const cFree = hts.cFree;

/// The ceiling the facade applies wherever it narrows a caller length or
/// count to upstream's narrower types.  Not a limit on every buffer; see
/// the defining declaration.
pub const max_stream_len = hts.max_stream_len;

/// Order-byte bits for the rANS 4x16 codec.
pub const order_flag = hts.order_flag;

/// Order-byte bits for the dynamic arithmetic coder.
pub const arith_order_flag = hts.arithOrderFlag;

/// Per-ISA kernel selection bits for `ransSetCpu`.
pub const cpu_flag = hts.cpu_flag;

/// Restricts which 32x16 kernels the library may select at run time.
pub const ransSetCpu = hts.ransSetCpu;

/// Library version as upstream's packed `HTSCODECS_VERSION` integer.
pub const version = hts.version;

/// Library version as upstream's `htscodecs_version()` string.
pub const versionText = hts.versionText;

/// Per-record metadata for the fqzcomp codec, borrowed and mutated in
/// place by `fqzcomp.compress`.
pub const Slice = hts.Slice;

pub const rans4x8 = hts.rans4x8;

pub const rans4x16 = hts.rans4x16;

pub const rans32x16 = hts.rans32x16;

pub const arith = hts.arith;

pub const fqzcomp = hts.fqzcomp;

pub const rle = hts.rle;

pub const tok3 = hts.tok3;

pub const pack = hts.pack;

/// The provider's own thread-local allocation pool.  See `htscodecs.tls`.
pub const tls = hts.tls;
