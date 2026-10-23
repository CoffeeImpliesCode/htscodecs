# Zig facade API

The typed facade wraps the translated C interface, which remains available as `c`.

## Module exports

| Name | Contract |
|---|---|
| `c` | Complete translated C declarations for the selected header set. |
| `runtime_loaded` | Comptime flag indicating whether native calls use a loaded provider. |
| `LoadSource`, `LoadError` | Request and failures for `load`. Sources are an explicit `.path` or `.system`; there is no fallback. |
| `load(source)` | In a runtime-loaded build, loads one provider and retains it for the process. Repeating the same request is safe; a different request after success returns `ProviderMismatch`. Failed loads publish nothing and can be retried. Concurrent same-request callers wait; re-entry returns `ReentrantLoad`. There is no unload. Calling `load` in a linked build panics. |
| `loadedSource()` | The retained request, or `null` before a successful load and in linked builds. |
| `Error` | Facade errors listed below. |
| `Owned`, `cFree` | Release facade-owned results or raw C pointers with libc `free`. |
| `max_stream_len` | `INT_MAX`, used only where a wrapper narrows a length or count to a C `int`/`unsigned int`. |
| `order_flag`, `arith_order_flag` | Order-byte constants for rANS 4x16 and the arithmetic coder. |
| `cpu_flag`, `ransSetCpu` | 32x16 kernel-selection mask; `none` forces scalar, `all` restores automatic detection. The call replaces the mask. |
| `version`, `versionText` | Upstream packed integer and NUL-terminated version string. |
| `Slice` | Per-record fqzcomp lengths and flags; `fqzcomp.compress` mutates it. |

`Error` distinguishes causes only when the facade can determine them:

| Error | Meaning |
|---|---|
| `LengthOverflow` | A length or count would be truncated by a narrower C parameter. |
| `InvalidArgument` | The facade rejects an unsupported order, strategy, inconsistent metadata, short map, invalid symbol count or checked overlap. |
| `BufferTooSmall` | A facade-side length check proves that a caller buffer cannot hold the result. |
| `OperationFailed` | Upstream returned `NULL`; its C API does not report why. |
| `AllocationFailed` | The upstream thread-local allocation pool returned `NULL` through `tls.alloc` or `tls.calloc`. |

A native `NULL` is never promoted to `BufferTooSmall`; malformed input,
capacity failure and allocation failure may be indistinguishable there.

## Codec namespaces

| Namespace | Operations and result |
|---|---|
| `rans4x8` | `compress`, `uncompress`; both return `Owned`. Order zero selects O0; any nonzero order selects O1. |
| `rans4x16` | `compressBound`, `compressTo`, `compress`, `uncompressTo`, `uncompress`; caller-buffer and `Owned` forms. `order_flag` selects codec options. |
| `rans32x16` | `compressTo`, `uncompressTo`; caller buffers, with order 0 or 1. |
| `arith` | `compressBound`, `compressTo`, `compress`, `uncompressTo`, `uncompress`; caller-buffer and `Owned` forms. |
| `fqzcomp` | `compress`, `decompress`, `decompressLengths`, `qualStats`; `compress` returns `Owned`. |
| `rle` | `Symbols`, `Encoded`, `max_rle_symbols`, `encode`, `decode`; caller buffers. |
| `tok3` | `encodeNames`, `decodeNames`; decoding returns `Owned`. |
| `pack` | `Meta`, `packData`, `unpackMeta`, `unpackTo`; `packData` returns `Owned`. |
| `tls` | `alloc`, `calloc`, `free` for upstream's separate scratch-allocation pool. |

`compressTo` and `uncompressTo` return the number of bytes used or written.
Use `compressBound` for compression destinations. rANS 4x16 STRIPE decoding
requires the destination to have the exact original length, not spare capacity.
`rle.encode` requires both `run` and `out` to hold at least `data.len` bytes;
`Symbols.count` must be 0..256, where zero asks the encoder to discover the set.

## Ownership and mutation

- `Owned` exposes `ptr` and `len`; `slice()` borrows that block. It comes from
  libc `malloc`, not a Zig allocator. Call `deinit()` exactly once on one
  handle; copies share the pointer, and slices become invalid after release.
  Use `cFree` for a raw malloc pointer returned through `c`.
- `tls.alloc` and `tls.calloc` return pointers for `tls.free`, not `cFree`.
  In threaded builds, allocate and free each pointer on the same thread.
- `fqzcomp.compress` mutates `Slice.len`, `Slice.flags` and its input. For
  `vers_3_1`, input records may be reversed while encoding; an early failure
  can leave them changed. Keep the three buffers separate.
- `tok3.encodeNames` replaces newline or NUL separators in its mutable block
  with NUL; a failed call can leave it partly rewritten.
- `rle.encode` updates `Symbols` in place. `pack.Meta.map` has 257 bytes;
  `packData` writes it before it can reject a wide alphabet, so metadata is
  meaningless if the call fails.
- `fqzcomp.decompressLengths` writes lengths as it decodes. Failure can leave
  a written prefix, and the provided array bounds how many records are returned.

## Aliasing

The facade rejects overlap for these pairs:

- `rans4x16` and `arith`: input vs output for compression and compressed input
  vs output for decompression.
- `rans32x16`: input vs output in either direction.
- `rle.encode`: `data` vs `run` and `data` vs `out`; `rle.decode`: `lit` and
  `run` vs `out`.
- `pack.unpackTo`: `data` vs `out`.
- `fqzcomp.decompressLengths`: `compressed` vs `lengths`.

Unlisted pairs are not checked. In particular, keep `rle.encode`'s `run` and
`out` separate, keep `pack.unpackMeta`'s `data` and map separate, and keep
`pack.packData`'s input and metadata map separate. `pack.unpackTo` does not
check map/output overlap. The two read-only `rle.decode` inputs may alias.
