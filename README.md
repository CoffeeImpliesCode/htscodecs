# htscodecs for Zig

A Zig 0.17.0 package for samtools/htscodecs v1.6.7.
It builds the upstream CRAM codecs and provides a Zig facade and C library.

## Source deviations from upstream

| Path | Change |
|---|---|
| `htscodecs/`, upstream headers, tests, scripts, fixtures and licence files | Retained without source changes. |
| `.gitignore` | Keeps upstream entries and adds Zig/Nix build outputs. |
| `README.md` | Fork-authored package guide; upstream's README is retained as `README.upstream.md`. |
| `include/htscodecs_config.h` | Derives feature macros from the selected target. |
| `include/htscodecs_all.h` | Aggregates bundled public headers for translation and installation. |
| `include/htscodecs_system.h` | Aggregates installed headers for system-library mode. |
| `root.zig`, `src/htscodecs.zig` | Expose the translated C API and typed Zig facade. |
| `runtime/` | Adds generated dispatch, provider loading and process-wide synchronization. |
| `fixtures.zig`, `test/*.zig` | Add Zig tests over the unchanged upstream fixtures and facade. |
| `examples/codec_demo.zig`, `consumer/` | Add an example and a separate package consumer. |

`rans_compress_O0_32x16_sse4` is declared by upstream for x86-64, but its
upstream definition remains disabled in an `#if 0` block. This fork does not
supply a replacement. A linked call has no definition; runtime loading treats
the symbol as optional, but calling it panics. Other target-declared provider
symbols are required.

## Build deviations

`build.zig` replaces Autotools. It generates `config.h` and `version.h` in the
build cache, derives target macros for both C compilation and header
translation, and compiles each 32x16 ISA kernel as a separate object with its
own feature flags. WASI uses upstream's `NO_THREADS` path.

The `-Dbz2=true` option enables the arithmetic coder's bzip2 method and links
libbz2; it is disabled by default. System-library mode translates the installed
headers and links the matching installed library instead of compiling bundled
sources.

## Support matrix

The default `zig build check` matrix compiles the facade, tests and example for
these targets; it does not run cross-target tests.

| Target | 32x16 kernels | Static | Shared/runtime |
|---|---|---:|---:|
| `x86_64-linux-gnu` | Scalar, SSE4, AVX2, AVX-512 | Yes | Yes |
| `aarch64-linux-gnu` | Scalar, Neon | Yes | Yes |
| `aarch64-macos-none` | Scalar, Neon | Yes | Yes |
| `x86_64-windows-gnu` | Scalar, SSE4, AVX2, AVX-512 | Yes | Yes |
| `riscv64-linux-gnu` | Scalar | Yes | Yes |
| `wasm32-wasi` | Scalar, `NO_THREADS` | Yes | No |

WASI has no dynamic linker, so only static linkage is available. Additional
compile-check targets are `aarch64-macos`, `x86_64-macos` and
`aarch64-windows-gnu`, selected with `-Dcheck-targets=`.

## Consumption

Add the package and import its module:

```sh
zig fetch --save git+https://github.com/CoffeeImpliesCode/htscodecs#v1.6.7
```

The module and library artifact are both named `htscodecs`; the module already
links the artifact. Use `dep.artifact("htscodecs")` for a C consumer. The
installation provides 13 headers under `include/htscodecs/` and a pkg-config
file named `htscodecs.pc`.

Build options:

- `-Dlinkage=static|dynamic` selects the C artifact; `static` is the default.
- `-Druntime=true` uses generated dispatch instead of linking the C library;
  the option is independent of linkage. A runtime provider must be loaded
  explicitly. This mode cannot be combined with system-library mode.
- `-Dbz2=true` enables the optional bzip2 method.
- `-fsys=htscodecs` uses the installed library and headers.
- `-Dcheck-targets=<list>` selects compile-check targets; `-Dtarget=` and
  `-Doptimize=` select the normal Zig target and optimization mode.
