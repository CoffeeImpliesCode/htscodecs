# Changelog

- System-mode translation now includes the required standard types; target-aware preprocessing handles libc headers that Zig's C parser cannot parse, and AArch64 big-endian builds include the NEON kernel.
- Reject negative FQZ strategies before native table access and guard `qualStats` record-count overflow; preserve upstream's custom-strategy clamp.
- Clarify that `pack.unpackTo` cannot infer the original decoded size; single-symbol output reports bytes written and leaves the remaining destination untouched.
- `devenv` tasks now run from the package root and use external Zig caches and install prefixes.
- The fork's README now occupies `README.md`; upstream's README remains at `README.upstream.md`.
- Nix exposes static and shared outputs from one source-only derivation, with static as the default.
- Runtime loading uses a generated dispatch and an explicit provider; the upstream-disabled SSE4 order-0 encoder remains unavailable.
- Requests for shared linkage fail on targets without a dynamic linker; static linkage remains available on WASI.
- Correct `pack.Meta.map` to 257 bytes and check map lengths before unpacking.
- Align facade errors with what the C API can report: unknown native failures return `OperationFailed`, and `InvalidArgument` covers wrapper-side checks.
- Restore caller-buffer `arith.compress` and `arith.uncompressTo`; bzip2 support remains opt-in.
- Make `tok3.encodeNames` and `fqzcomp.compress` inputs mutable where upstream edits them; use `u32` for FQZ lengths and flags.
- Enforce `rle.encode` output bounds and document that STRIPE `rans4x16.uncompressTo` requires an exactly sized destination.
- Add the `-fsys=htscodecs` mode, which translates installed headers and links the matching system library.
- Generate version metadata from the pinned release instead of `git describe`; `htscodecs_version()` returns the release version.
- Share generated feature macros between C compilation and translation, including the WASI no-threads fallback and optional bzip2 support.
- Compile 32x16 ISA kernels as separate target-specific objects so the scalar dispatcher keeps its baseline.
- Build the C library directly with `build.zig` without configure, make, or build-time downloads; keep the upstream autotools files available.
