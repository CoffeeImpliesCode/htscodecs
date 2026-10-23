// SPDX-License-Identifier: BSD-3-Clause
//
//! htscodecs provider checks for the target's translated headers.
//! Rejects providers missing required symbols; absent optional SSE4 compressor panics by name.
//! Codec allocations use libc `free`; TLS allocations use `htscodecs_tls_free`.
const rt = @import("rt");
const std = @import("std");

/// Namespaced synchronization hooks for this loader.
/// Their prefix must match `RT_SYNC_PREFIX` from `runtime/graph.zig`.
pub const Sync = struct {
    extern fn htscodecs_rt_lock() void;
    extern fn htscodecs_rt_unlock() void;
    extern fn htscodecs_rt_wait() void;
    extern fn htscodecs_rt_broadcast() void;
    // C `unsigned long long` maps to `u64` on supported targets.
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

/// Returns the loader configuration for the generated dispatch.
/// The type parameter avoids importing the dispatch back into this file.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Name included in the pre-load panic.
        pub const library_name = "htscodecs";

        /// Dispatch table and target-specific symbol lists.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// Namespaced synchronization hooks.
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

        /// Assigns an optional resolved address or clears its field.
        pub inline fn assignOptional(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assignOptional(index, dst, address);
        }

        pub inline fn assignMissing(comptime index: usize, dst: *table) void {
            dispatch.assignMissing(index, dst);
        }

        /// Checks two deterministic upstream behaviors before publishing the table.
        /// The checks allocate nothing and read no global state.
        pub fn validate(dst: *const table) ?[]const u8 {
            // Compare the provider's bound with upstream's formula (`rANS_static4x16pr.c`).
            const bound_cases = [_]struct { size: c_uint, order: c_int, what: []const u8 }{
                // order 0 uses the no-method arm.
                .{ .size = 0, .order = 0, .what = "size 0, order 0" },
                .{ .size = 1000, .order = 0, .what = "size 1000, order 0" },
                .{ .size = 1000, .order = 1, .what = "size 1000, order 1" },
                // Cover method flags and STRIPE's packed count.
                .{ .size = 4096, .order = 0x80 | 1, .what = "PACK" },
                .{ .size = 4096, .order = 0x40 | 1, .what = "RLE" },
                .{ .size = 4096, .order = 0x04 | 1, .what = "X32" },
                .{ .size = 4096, .order = 0x08 | (7 << 8), .what = "STRIPE with N=7" },
            };
            inline for (bound_cases) |case| {
                const want = boundFromSource(case.size, case.order);
                const got = dst.rans_compress_bound_4x16(case.size, case.order);
                if (got != want) {
                    return "rans_compress_bound_4x16 answered a size/order pair " ++
                        "this build's own header arithmetic does not produce, " ++
                        "so the provider's int/unsigned int semantics or its " ++
                        "order-byte constants are not the ones this build was " ++
                        "configured for (" ++ case.what ++ ")";
                }
            }

            // This five-byte packed header represents four symbols (`pack.c`).
            // `map` is caller-owned.
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

/// Mirrors `rANS_static4x16pr.c` and constants in `rANS_static4x16.h`.
/// Preserve double arithmetic and truncation to match C.
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
