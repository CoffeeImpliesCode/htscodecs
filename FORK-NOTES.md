# Fork notes

## Source deviations

The upstream C implementation, installed headers, tests, scripts, licences, and fixture data are unchanged. The fork additions and replacements are:

| Path | Change and reason |
|---|---|
| `.gitignore` | Appends Zig and Nix build-output rules while preserving upstream entries. |
| `README.md` | Replaces upstream build instructions; the original is retained as `README.upstream.md`. |
| `include/htscodecs_config.h` | Replaces configure-generated feature answers with target-derived macros shared by C compilation and translation. |
| `include/htscodecs_all.h` | Aggregates the bundled public headers and required standard types for translation and installation. |
| `include/htscodecs_system.h` | Aggregates installed system headers so translation matches the library actually linked. |
| `root.zig` | Publishes the translated C interface and typed codec namespaces as the package module. |
| `src/htscodecs.zig` | Adds thin typed wrappers that check narrowing and aliasing and make C allocation ownership explicit. |
| `runtime/graph.zig` | Wires translated declarations, generated dispatch, loader, and synchronization into the optional runtime route. |
| `runtime/generate.zig` | Generates typed dispatch wrappers from the selected target's translated declarations. |
| `runtime/library.zig` | Defines the provider's target-specific symbol and ABI contract for the loader. |
| `runtime/loader.zig` | Adds explicit platform loading with validation before publishing the process-wide dispatch table. |
| `runtime/sync.c`, `runtime/sync.h` | Add prefixed process-wide synchronization for concurrent load attempts. |
| `fixtures.zig`, `test/*.zig` | Add Zig tests over the unchanged fixture corpus and facade. |
| `examples/codec_demo.zig`, `consumer/` | Add a codec example and a separate package consumer. |

## Build-graph deviations

- `build.zig` replaces Autotools; it compiles upstream translation units directly and creates `config.h` and `version.h` in the build cache.
- The aggregate header is translated for the selected target. Translation uses Aro directly where possible and `zig cc -E -dD` before Aro for NetBSD, OpenBSD, and x86 Windows target headers.
- Each 32x16 ISA kernel is a separate object with its own feature flags. SSE4, AVX2, and AVX512 objects target x86-64; Neon targets AArch64, including big-endian AArch64. Runtime CPU detection selects available kernels.
- `-Dbz2=true` enables the arithmetic coder's bzip2 method and requires libbz2 development files; it is off by default.
- `-Dlinkage=static|dynamic` selects the C artifact; static is the default. Dynamic builds use PIC and platform export metadata, and are refused where the target has no dynamic linker.
- `-Druntime=true` builds the dispatch without linking the C library; the caller must load a compatible provider explicitly. This mode is incompatible with `-fsys=htscodecs`.
- `-fsys=htscodecs` translates installed system headers and links the installed library instead of building the bundled sources.
- WASI defines upstream's `NO_THREADS` fallback because wasi-libc declares pthread APIs without implementing the required thread-local operations.

## Known platform and API boundaries

- WASI supports static linkage only; it has no dynamic loader. Its `NO_THREADS` build uses the upstream non-threaded allocation path.
- `rans_compress_O0_32x16_sse4` is declared upstream but its definition is disabled in upstream source. The runtime route treats it as optional; a linked caller needs another definition.
- The runtime provider must export the symbols declared by the selected target's headers and satisfy the recorded ABI checks; a provider built for a narrower ISA set is rejected.
- The `thumbeb` 32-bit big-endian Arm path has a known codec-output mismatch; its cause is unresolved. This does not establish behavior for `armeb` targets.
