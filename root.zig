//! htscodecs: the CRAM external-block codecs, packaged for Zig 0.16.
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
//!   `arith`, `fqzcomp`, `rle`, `tok3` and `pack` - which choose the right
//!   upstream entry point, check length narrowing, and make buffer
//!   ownership explicit.
//!
//! ```zig
//! const htscodecs = @import("htscodecs");
//!
//! const payload = "the quick brown fox jumps over the lazy dog" ** 8;
//!
//! // The destination is the compressor's bound, and the decompress
//! // destination is the payload's own length.  Exact sizing matters: a
//! // stream carrying the STRIPE order bit is rejected outright if the
//! // destination is *larger* than the original, not just if it is
//! // smaller.  See `rans4x16.uncompressTo`.
//! const bound = try htscodecs.rans4x16.compressBound(payload.len, 0);
//! const scratch = try allocator.alloc(u8, bound);
//! defer allocator.free(scratch);
//! const n = try htscodecs.rans4x16.compressTo(payload, scratch, 0);
//!
//! const plain = try allocator.alloc(u8, payload.len);
//! defer allocator.free(plain);
//! const m = try htscodecs.rans4x16.uncompressTo(scratch[0..n], plain);
//! assert(std.mem.eql(u8, plain[0..m], payload));
//! ```

const std = @import("std");
const hts = @import("src/htscodecs.zig");

/// Complete translated C interface for include/htscodecs_all.h.
pub const c = hts.c;

/// Failures reported by the facade.
pub const Error = hts.Error;

/// A buffer upstream allocated with `malloc`; free it with `deinit`.
pub const Owned = hts.Owned;

/// Frees a pointer from one of upstream's `malloc`-ing entry points.
pub const cFree = hts.cFree;

/// Upstream's hard ceiling on any buffer length it is handed.
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

/// Per-record metadata for the fqzcomp codec.
pub const Slice = hts.Slice;

pub const rans4x8 = hts.rans4x8;
pub const rans4x16 = hts.rans4x16;
pub const rans32x16 = hts.rans32x16;
pub const arith = hts.arith;
pub const fqzcomp = hts.fqzcomp;
pub const rle = hts.rle;
pub const tok3 = hts.tok3;
pub const pack = hts.pack;
