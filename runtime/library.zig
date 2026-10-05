// SPDX-License-Identifier: BSD-3-Clause
//
//! htscodecs's side of the runtime loader: the names its synchronization
//! binding has, and what it requires of a provider beyond resolving its
//! symbols.
//!
//! Everything else about the runtime route is generic. `runtime/loader.zig`
//! is the state machine and the platform layer; `runtime/generate.zig` builds
//! the dispatch from whatever the translation step actually produced;
//! `runtime/graph.zig` wires them together. This file is what makes them
//! htscodecs's, and it is the file another SDK replaces.
//!
//! ## What a provider must be
//!
//! Every function the installed header set declares, all 42 of them at this
//! pin, in five families:
//!
//!   * `htscodecs.h` - `htscodecs_version` (`htscodecs/htscodecs.h:53`).
//!   * `pack.h` - `hts_pack`, `hts_unpack_meta`, `hts_unpack`
//!     (`htscodecs/pack.h:52`, `:66`, `:80`).
//!   * `rle.h` - `hts_rle_encode`, `hts_rle_decode` (`htscodecs/rle.h:69`,
//!     `:84`).
//!   * `rANS_static.h`, `rANS_static4x16.h` and `rANS_static32x16pr.h` -
//!     `rans_compress`, `rans_uncompress`, `rans_compress_bound_4x16`,
//!     `rans_compress_to_4x16`, `rans_compress_4x16`,
//!     `rans_uncompress_to_4x16`, `rans_uncompress_4x16`, `rans_set_cpu`,
//!     the four scalar 32x16 kernels and, where this target's
//!     `htscodecs_config.h` declared them, the SSE4, AVX2, AVX512 and Neon
//!     32x16 kernels.
//!   * `arith_dynamic.h`, `tokenise_name3.h`, `fqzcomp_qual.h` and
//!     `utils.h` - the five `arith_*` entry points, `tok3_encode_names`,
//!     `tok3_decode_names`, `fqz_compress`, `fqz_decompress`,
//!     `fqz_qual_stats`, `htscodecs_tls_alloc`, `htscodecs_tls_calloc` and
//!     `htscodecs_tls_free`.
//!
//! One declared entry point has no native implementation in this pin.
//! `rans_compress_O0_32x16_sse4` is declared by `rANS_static32x16pr.h`, but
//! upstream disables its definition with `#if 0` at
//! `rANS_static32x16pr_sse4.c:113-460`. The runtime table keeps it optional.
//! Calling it without a provider export causes a named panic. No scalar
//! substitute runs. A linked call also needs an external definition.
//!
//! `hts_unpack_` is not declared by `pack.h`, so it is not in the table.
//!
//! The per-ISA set is target-derived rather than fixed. `rANS_static32x16pr.h`
//! gates the SSE4 kernels on `HAVE_SSE4_1 && HAVE_SSSE3 && HAVE_POPCNT`
//! (`:82`), the AVX2 kernels on `HAVE_AVX2` (`:101`) and the AVX512 kernels on
//! `HAVE_AVX512` (`:125`), all three of which `include/htscodecs_config.h`
//! derives from `__x86_64__` (`:74`-`:90`); the Neon kernels are gated on
//! `__ARM_NEON && __aarch64__` (`rANS_static32x16pr.h:149`). The generator
//! reads this target's own translation, so the table asks for exactly the
//! kernels this target declares. A provider compiled for a narrower ISA set
//! than the one this build was configured for is refused at load rather than
//! half used.
//!
//! ## The ABI boundary, stated honestly
//!
//! **Call shape.** C linkage, one return value, fixed argument lists
//! everywhere. No header-declared function is variadic and none takes a
//! function pointer, so there is no callback whose calling convention this
//! route would have to reproduce. The only callback in the library is the
//! destructor `utils.c:104` hands to `pthread_key_create`, which lives inside
//! the provider.
//!
//! **Scalars.** `int` and `unsigned int` (32-bit on every target this SDK
//! builds for), `int64_t`, `uint64_t`, `uint32_t`, `uint16_t`, `uint8_t`, and
//! `size_t`. No `long double`, no `_Bool`, no `float`, no bitfield crosses
//! the boundary. `double` appears in the translation only as the argument and
//! return of the inline `fast_log` (`htscodecs/utils.h:69`), which
//! `runtime/graph.zig` keeps direct rather than routing.
//!
//! **Layouts.** Two structs cross by pointer and both are caller-allocated:
//! `fqz_slice` (`fqzcomp_qual.h:59`-`:63`: one `int` then two pointers) and
//! `fqz_param` (`fqzcomp_qual.h:90`-`:122`), which `fqz_qual_stats` fills.
//! `fqz_gparams` (`fqzcomp_qual.h:127`-`:136`) is declared but this facade
//! only ever passes NULL for it, so no provider-written field is read back.
//! No header-declared function returns a struct by value.
//!
//! **Allocator.** The `malloc`-ing entry points - `rans_compress`,
//! `rans_uncompress`, `rans_compress_4x16`, `rans_uncompress_4x16`,
//! `arith_compress`, `arith_uncompress`, `fqz_compress`, `fqz_decompress`,
//! `tok3_encode_names`, `tok3_decode_names`, `hts_pack` - allocate with
//! plain libc `malloc` (`rANS_static.c:77`, `rANS_static4x16pr.c:1040`,
//! `arith_dynamic.c:100`, `fqzcomp_qual.c:1008`) and *not* with
//! `htscodecs_tls_alloc`. `Owned.deinit` therefore pairs with libc `free`
//! in every configuration, and that stays true of a runtime-loaded provider
//! because it is loaded into this process and shares its allocator.
//!
//! `htscodecs_tls_alloc`/`calloc`/`free` are a separate family with their
//! own pairing: what they return is released with `htscodecs_tls_free`
//! (`htscodecs/utils.c:119`-`:208` for the threaded pool, `:223`-`:233` for
//! the plain `calloc`/`free` fallback). They are routed, so a consumer that
//! wants scratch memory from the provider's own pool gets it through the
//! same table as everything else.
//!
//! **Threads.** `utils.c` builds its pool on `pthread_once` and
//! `pthread_key_create` unless `NO_THREADS` is defined, which
//! `include/htscodecs_config.h:99`-`:103` does for `__wasi__`. A provider
//! for a threaded target carries that dependency inside itself and the
//! loader does not resolve it.
//!
//! **The bzip2 closure is a provider-side dependency and configuration.**
//! `arithOrderFlag.ext` is the one order bit whose meaning depends on how
//! the provider was built. `arith_dynamic.c` reaches for exactly two libbz2
//! entry points, `BZ2_bzBuffToBuffCompress` (`:964`) and
//! `BZ2_bzBuffToBuffDecompress` (`:1227`), and only under `HAVE_LIBBZ2`,
//! which `include/htscodecs_config.h:122`-`:126` sets from
//! `HTSCODECS_WITH_BZ2`. Neither name appears in any installed htscodecs
//! header, so neither is in this table: they are the provider's own
//! dependency, resolved when the provider's own shared object is loaded, and
//! a provider built with `-Dbz2=true` whose libbz2 cannot be found fails to
//! load at all. The consequence for a consumer is narrow and worth stating:
//! a provider built *without* bzip2 satisfies everything above, and a stream
//! produced with `arithOrderFlag.ext` simply cannot be read by one - which
//! arrives as the ordinary NULL return and so as
//! `error.OperationFailed`, indistinguishable from every other failure of
//! that call.
//!
//! **What is checked at load time.** Only the two facts below. Resolving the
//! symbols and translating the header are the boundary; they are not proof
//! that a provider is compatible, and this file does not pretend to add
//! more. `validate` calls two entry points that touch no memory the caller
//! did not hand them, allocate nothing, and read no global state, and
//! compares what they answer against what the upstream sources define. That
//! is a compatibility signal, not a verdict: a provider can pass it and
//! still be a different build of the library.
const rt = @import("rt");
const std = @import("std");

/// The synchronization this loader calls, bound by exact name.
///
/// The names below are `runtime/sync.h` compiled with
/// `RT_SYNC_PREFIX=htscodecs_rt`, which is what `runtime/graph.zig` passes.
/// Two spellings of that prefix have to agree: this file names the symbols,
/// and graph.zig defines the macro. A build where they disagree does not
/// link, and that is the whole error report: there is no runtime path that
/// could hide it.
///
/// The core in `runtime/loader.zig` never names a symbol of its own, which
/// is what lets two SDKs, or two configurations of one SDK, hold their own
/// loader state in one process without sharing any of it.
pub const Sync = struct {
    extern fn htscodecs_rt_lock() void;
    extern fn htscodecs_rt_unlock() void;
    extern fn htscodecs_rt_wait() void;
    extern fn htscodecs_rt_broadcast() void;
    // `unsigned long long`. Declared as u64, which is the same type in every
    // ABI this SDK targets: 64-bit on x86_64, aarch64, riscv64 and wasm32.
    extern fn htscodecs_rt_thread_self() u64;

    pub fn lock() void {
        htscodecs_rt_lock();
    }
    pub fn unlock() void {
        htscodecs_rt_unlock();
    }
    pub fn wait() void {
        htscodecs_rt_wait();
    }
    pub fn broadcast() void {
        htscodecs_rt_broadcast();
    }
    pub fn threadSelf() u64 {
        return htscodecs_rt_thread_self();
    }
};

/// The loader's configuration for this SDK, given the dispatch that owns the
/// table.
///
/// `dispatch` is the generated module, passed as a type by the dispatch
/// itself so that this file never has to import it. The direction is one-way
/// on purpose: the descriptor knows what the loader needs, the dispatch knows
/// what the header said, and neither imports the other.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Named in the pre-load panic, so the message says which library was
        /// reached for before it was loaded.
        pub const library_name = "htscodecs";

        /// The table the generated dispatch declares, and the symbols it needs
        /// to fill it. Both come from the translated header, not from this file.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// The project's namespaced synchronization binding.
        pub const sync = Sync;

        pub fn tablePtr() *table {
            return dispatch.tablePtr();
        }

        pub fn ready() *rt.Ready {
            return &dispatch.ready;
        }

        pub fn assign(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assign(index, dst, address);
        }

        /// One resolved address into one optional table field, and the empty
        /// case beside it. Both index `optional_symbols`, not `symbols`.
        pub inline fn assignOptional(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assignOptional(index, dst, address);
        }

        pub inline fn assignMissing(comptime index: usize, dst: *table) void {
            dispatch.assignMissing(index, dst);
        }

        /// The library-specific check, run after every symbol resolved and
        /// before anything is published.
        ///
        /// Both facts below are pure functions of the arguments, and both are
        /// fully determined by the upstream sources: nothing here allocates,
        /// reads a global, or depends on what the caller did before it. That
        /// is what makes them safe to call between "the symbols resolved" and
        /// "the table may be read".
        pub fn validate(dst: *const table) ?[]const u8 {
            // 1. `rans_compress_bound_4x16` is the header's own promise about
            //    buffer sizing and nothing else: it allocates nothing and
            //    touches no memory. Its answer is fixed by the arithmetic in
            //    `htscodecs/rANS_static4x16pr.c:93`-`:107`, transcribed below
            //    line for line, including the `double` the expression is
            //    evaluated in and the truncation back to `unsigned int`. A
            //    provider whose `int`/`unsigned int` widths, or whose
            //    order-byte constants, differ from this build's answers
            //    differently here.
            const bound_cases = [_]struct { size: c_uint, order: c_int, what: []const u8 }{
                // order 0 takes the `order == 0` arm with no method bits.
                .{ .size = 0, .order = 0, .what = "size 0, order 0" },
                .{ .size = 1000, .order = 0, .what = "size 1000, order 0" },
                // Any non-zero order takes the order-1 arm.
                .{ .size = 1000, .order = 1, .what = "size 1000, order 1" },
                // One case per method bit, so a provider that disagrees about
                // any single constant disagrees about the bound.
                .{ .size = 4096, .order = 0x80 | 1, .what = "PACK" },
                .{ .size = 4096, .order = 0x40 | 1, .what = "RLE" },
                .{ .size = 4096, .order = 0x04 | 1, .what = "X32" },
                // STRIPE takes N from bits 8-15 and uses it in the bound.
                .{ .size = 4096, .order = 0x08 | (7 << 8), .what = "STRIPE with N=7" },
            };
            inline for (bound_cases) |case| {
                const want = boundFromSource(case.size, case.order);
                const got = dst.rans_compress_bound_4x16(case.size, case.order);
                if (got != want) {
                    // Reported as a message rather than a value comparison,
                    // because the number a mismatched provider produces is
                    // not a fact anybody can act on; the input pair is.
                    return "rans_compress_bound_4x16 answered a size/order pair " ++
                        "this build's own header arithmetic does not produce, " ++
                        "so the provider's int/unsigned int semantics or its " ++
                        "order-byte constants are not the ones this build was " ++
                        "configured for (" ++ case.what ++ ")";
                }
            }

            // 2. `hts_unpack_meta` reads a packed-stream header into a map the
            //    caller owns and writes nothing else. The five bytes below are
            //    a four-symbol header, and `pack.c:161`-`:190` fixes the whole
            //    answer: `data[0]` is the symbol count, `n <= 4` selects four
            //    symbols per byte, and the count bytes follow it.
            var header = [_]u8{ 4, 0xAA, 0xBB, 0xCC, 0xDD };
            var map: [256]u8 = @splat(0);
            var nsym: c_int = -1;
            const consumed = dst.hts_unpack_meta(&header, header.len, 0, &map, &nsym);
            if (consumed != header.len or nsym != 4) {
                return "hts_unpack_meta did not read a four-symbol packed header " ++
                    "the way pack.c defines it, so the provider's byte, " ++
                    "32-bit and int handling is not the one this build was " ++
                    "configured for";
            }
            if (!std.mem.eql(u8, map[0..4], header[1..5])) {
                return "hts_unpack_meta wrote a symbol map that is not the header " ++
                    "it was given, so the provider's pointer handling is not " ++
                    "the one this build was configured for";
            }
            return null;
        }
    };
}

/// `htscodecs/rANS_static4x16pr.c:93`-`:107`, transcribed.
///
/// The C text is
///
/// ```c
/// unsigned int rans_compress_bound_4x16(unsigned int size, int order) {
///     int N = (order>>8) & 0xff;
///     if (!N) N=4;
///     order &= 0xff;
///     unsigned int sz = (order == 0
///         ? 1.05*size + 257*3 + 4
///         : 1.05*size + 257*257*3 + 4 + 257*3+4) +
///         ((order & RANS_ORDER_PACK) ? 1 : 0) +
///         ((order & RANS_ORDER_RLE) ? 1 + 257*3+4: 0) + 20 +
///         ((order & RANS_ORDER_X32) ? (32-4)*4 : 0) +
///         ((order & RANS_ORDER_STRIPE) ? 7 + 5*N: 0);
///     return sz + (sz&1) + 2;
/// }
/// ```
///
/// and the bit values are `rANS_static4x16.h:70`-`:88`. The sum is evaluated
/// in `double` and truncated to `unsigned int`, which is why the `double`
/// appears here rather than an integer rewrite of it: a different rounding
/// would answer differently, and the rounding is part of what is being
/// checked.
fn boundFromSource(size: c_uint, order: c_int) c_uint {
    var n: c_int = (order >> 8) & 0xff;
    if (n == 0) n = 4;
    const masked: c_int = order & 0xff;

    const pack: c_int = if ((masked & 0x80) != 0) 1 else 0;
    const rle: c_int = if ((masked & 0x40) != 0) 1 + 257 * 3 + 4 else 0;
    const x32: c_int = if ((masked & 0x04) != 0) (32 - 4) * 4 else 0;
    const stripe: c_int = if ((masked & 0x08) != 0) 7 + 5 * n else 0;

    const base: f64 = if (masked == 0)
        1.05 * @as(f64, @floatFromInt(size)) + 257 * 3 + 4
    else
        1.05 * @as(f64, @floatFromInt(size)) + 257 * 257 * 3 + 4 + 257 * 3 + 4;

    const total = base + @as(f64, @floatFromInt(pack)) +
        @as(f64, @floatFromInt(rle)) + 20 +
        @as(f64, @floatFromInt(x32)) +
        @as(f64, @floatFromInt(stripe));
    const sz: c_uint = @intFromFloat(total);
    return sz + (sz & 1) + 2;
}