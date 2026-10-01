# Changelog

Fork-only changes, newest first.  Upstream's own release history is in
`NEWS.md`, which is untouched.  Every entry here is a divergence from
upstream v1.6.7 (`b9fc194f772e45bb0a1f44b08cbf8697a1384bae`); see
`UPSTREAM.md`.

## 1. Zig 0.16 build replaces configure and make

`build.zig` and `build.zig.zon` build the complete upstream C library from
the sources in this repository.  No CMake, no autotools, no `make`, no
download at build time and no system-installed copy by default.  The
translation units are exactly those in `htscodecs/Makefile.am`
(`libhtscodecs_base_src`) plus the four per-ISA 32x16 kernels.

Consequences for a caller:

* `zig build` installs `libhtscodecs.a` (or the platform's static form) and
  the public headers under `include/htscodecs/`.
* `dep.module("htscodecs")` is the whole interface: the translated C, the
  facade, and the library artifact already linked.
* `-fsys=htscodecs` switches to an installed `libhtscodecs` instead.  In that
  mode the translated interface is built from the *system's* headers, never
  from this tree's, so the declarations and the linked ABI always come from
  the same place.

The autotools build is left intact and still works for anyone who wants it.

## 2. Feature macros move from autoconf into a shared header

`configure.ac` probed `HAVE_BUILTIN_PREFETCH`, `HAVE_DECL___CPUID_COUNT`,
`HAVE_DECL___GET_CPUID_MAX`, `HAVE_SSE4_1`, `HAVE_SSSE3`, `HAVE_POPCNT`,
`HAVE_AVX2`, `HAVE_AVX512`, `HAVE_LIBBZ2` and the `NO_THREADS` fallback.
The Zig build decides the same questions with ordinary preprocessor
conditionals in `include/htscodecs_config.h`, which both the C compilation
and `b.addTranslateC` read, so the two can never disagree.

Specific answers, and why:

* `HAVE_DECL___CPUID_COUNT` / `HAVE_DECL___GET_CPUID_MAX`: defined on every
  x86-64 target.  `<cpuid.h>` ships in Zig's bundled compiler headers, so
  it resolves without a system GCC.  Without these two macros
  `rANS_static4x16pr.c` silently drops to its scalar path.
* `HAVE_SSE4_1`, `HAVE_SSSE3`, `HAVE_POPCNT`, `HAVE_AVX2`, `HAVE_AVX512`:
  defined on x86-64, matching upstream, where they are defined whenever the
  compiler accepts the corresponding intrinsics.
* `NO_THREADS`: defined on `wasm32-wasi`.  wasi-libc declares
  `pthread_once` and `pthread_key_create` but does not implement them, so
  upstream's own non-pthread fallback is the only buildable one there.
  Everywhere else pthreads are used, as upstream does.
* `HAVE_LIBBZ2`: off unless the build is given `-Dbz2=true`.

## 3. Per-ISA 32x16 kernels are separate objects

Upstream builds `rANS_static32x16pr_{sse4,avx2,avx512}.c` and
`rANS_static32x16pr_neon.c` as libtool convenience libraries so the scalar
object never picks up AVX code.  This fork does the same thing with
`b.addObject` plus per-object `-m` flags, adding only the kernels whose
architecture matches the target.  Runtime dispatch inside
`rANS_static4x16pr.c` is unchanged, so `rans4x16.compress` still selects
the best kernel on the running CPU.

## 4. bzip2 is opt-in

`-Dbz2=true` compiles the arithmetic coder's `X_EXT` method and links
`-lbz2`.  Without it, `arith_compress` prints
`Htscodecs has been compiled without libbz2 support` and returns NULL, and
`arith_uncompress` fails, which the facade reports as `error.OperationFailed`.
Streams that were written with bzip2 cannot be decoded by such a build.  One
upstream fixture, `tests/dat/arith/u32.4`, is in exactly that state, and the
tests say so rather than pretending it decodes.

## 5. A Zig facade, the translated C, and embedded fixtures

* `root.zig` publishes the translated C as `htscodecs.c` and the facade
  namespaces `rans4x8`, `rans4x16`, `rans32x16`, `arith`, `fqzcomp`,
  `rle`, `tok3` and `pack`.
* `Owned` wraps the buffers upstream `malloc`s and frees them with
  `std.c.free`.  Where upstream has a `*_to` entry point, the facade writes
  into a caller buffer and allocates nothing.  No process-global allocator
  hook is installed and nothing is copied on the way in or out.
* `fixtures.zig` embeds `tests/dat` and `tests/names` with `@embedFile` so
  the tests need no file system.  It is generated mechanically from a
  directory listing and contains no hand-written bytes.
* `examples/codec_demo.zig`, `test/` and `consumer/` are new.

## 6. Continuous integration points at this fork

`.cirrus.yml`, `.github/workflows/unix-build.yml` and
`.github/workflows/windows-build.yml` are removed and replaced by
`.github/workflows/verify.yml`.  The originals run `autoreconf`, `./configure`
and `make check` on the upstream maintainer's Cirrus CI and AppVeyor
infrastructure, and `README.md` carries a Cirrus badge pointing at it.  None
of that describes this fork.

`README.md` itself is untouched, so it still shows the upstream badge and
the upstream build instructions.  `README.zig.md` is the entry point for the
Zig build.

## 7. Version string is baked in, not derived from git

Upstream generates `htscodecs/version.h` from `git describe --dirty`.  A
pinned release does not need git at build time, and `--dirty` would report
this fork's additions as an upstream modification, so `build.zig` writes the
tagged version instead.  `htscodecs_version()` still returns a string; for
this fork it is `1.6.7`.

## 8. `.gitignore` gains the Zig build outputs

`.gitignore` is otherwise untouched: all 47 upstream entries keep their
order, because they still describe the autotools build that is left in the
tree.  A block is appended covering `.zig-cache/` and `zig-out/`, the two
directories `zig build` creates by default in Zig 0.16, so an ordinary
build does not leave untracked output for the next commit to sweep up.  The
patterns carry no leading slash, so they also cover `consumer/`, which is a
separate package.

Both manifests additionally use an explicit allowlist in `paths` rather than
`.paths = .{""}`, so a build directory cannot enter a package hash even if
one exists.  See `FORK-NOTES.md` entry 19.

## 9. Facade corrections found by review

These are public API changes to the facade, not to the C library.  Each one
is a case where the wrapper promised something upstream does not do, or
offered something it did not provide.  See `FORK-NOTES.md` entries 20-22.

* `arith` regains `uncompressTo` and `compress`.  Both directions of the
  arithmetic coder have caller-buffer forms; the decode wrapper was
  missing, which left six call sites in the tests and the consumer
  referring to a function that did not exist.
* `tok3.encodeNames` takes `block: []u8`, not `[]const u8`.
  `tok3_encode_names` rewrites every separator to NUL in place
  (`tokenise_name3.c:1500`), so the previous signature promised immutability
  the wrapper did not deliver — and its own test was writing into a string
  literal.
* `fqzcomp.compress` takes `in: []u8`, and `Slice.len` and `Slice.flags`
  are `[]u32`.  The codec clamps the lengths, ORs its selector into the
  flags, and reverses flagged quality records before encoding a CRAM 3.1
  stream. The success path restores those bytes; an early failure may not.
* `pack.Meta.map` grows to 257 bytes, because `hts_pack` writes
  `out_meta[256]` before it checks that the alphabet is narrow enough.
  `pack.unpackMeta` and `pack.unpackTo` take the map as a slice with a
  checked minimum length. `unpackTo` refuses `nsym == 1` when input exceeds
  destination capacity and reports only `data.len` bytes on that copy path,
  leaving the unwritten destination tail alone.
* The error set is re-cut around what the facade actually knows.  A NULL
  from upstream can mean the stream was malformed, the capacity was
  insufficient, the method is compiled out, or an allocation failed, and
  the C API collapses all four, so every post-call NULL is
  `error.OperationFailed` and nothing more specific.  `error.Malformed` is
  gone: the name was a diagnosis the wrapper could not support.
  `error.BufferTooSmall` survives only where the facade compared two lengths
  the caller supplied and knows the destination is too small — a zero-length
  destination, and `pack.unpackTo`'s `nsym == 1` copy.  A new
  `error.InvalidArgument` covers arguments the facade rejects itself: an
  unimplemented order byte, a record array that contradicts
  `Slice.num_records`, and a symbol map under 256 bytes.  `error.LengthOverflow`
  is unchanged.
* The symbol-map length check runs in every build mode.  It is an ordinary
  `map.len < 256` comparison in `unpackMeta` and `unpackTo`, not the
  `std.debug.assert` inside the private pointer helper, which vanishes in
  ReleaseFast.  A regression test pins the boundary: 255 bytes is refused
  with `error.InvalidArgument` and 256 is accepted and filled.
* `rans4x16.uncompressTo` documents that a STRIPE stream requires an
  exactly-sized destination, because upstream compares the stream's length
  against the capacity for equality.  The usage examples were changed from
  round-sized arrays to exactly-sized ones for the same reason.

## 10. Corrections from the first gate run

Both items below come from gates the parent ran on this fork.  No gate has
been re-run since, so neither entry claims anything beyond the receipt it
cites.

* `build.zig.zon` now carries `.fingerprint = 0x1cae8edb6408e4ce`, the value
  the pinned Zig 0.16.0 toolchain named when it rejected the placeholder
  that `zig init --minimal` had written.  The manifest is read before the
  build starts, so this is the first thing the native-build gate had to
  say.  See `FORK-NOTES.md` entry 23.
* The local name `packed` became `encoded` throughout the fork's own Zig
  sources: the two test files, the example, the consumer and the
  documented snippet in `README.zig.md`.  `packed` is a Zig keyword
  (`std/zig/tokenizer.zig:43`), and the four files the formatter named held
  eleven further occurrences that the diagnostic never reached.  No public
  declaration changed name.  See `FORK-NOTES.md` entry 24.

## 11. Build-script and CI corrections from source review

Four defects found by reading the pinned toolchain and this fork's own
records.  None of them has been run: the build script has not been compiled
and the workflow has not executed.  See `FORK-NOTES.md` entries 25-28.

* `build.zig` checks the provenance files against the package build root
  with the Zig 0.16 filesystem API.  `std.fs.cwd()` no longer exists, every
  `Io.Dir` method takes the `Io` as a parameter, and the process working
  directory is not this tree at all for a package consumed through
  `b.dependency()`.  The call is now
  `b.build_root.handle.access(b.graph.io, path, .{})`, with `FileNotFound`
  distinguished from any other error, and `git -C` takes the same root
  rather than `.`.
* The provenance gate is two steps.  `zig build provenance` checks that the
  licence and provenance records are present; that is a property of the
  sources, so it runs offline and stays in an ordinary `zig build`.
  `zig build provenance-history` checks that the pinned upstream commit is
  still in this clone's history; CI runs it where a clone exists, and where
  the history is absent it fails instead of reporting a success it did not
  observe.  A source package fetched without `.git` therefore builds.
* The CI check that upstream files are unmodified no longer lists
  `.gitignore`, because entry 8 documents a deliberate append in it.  It is
  not replaced by a diff of this fork's own bookkeeping against itself: a
  step that asserts the appended lines are literally `.zig-cache/` and
  `zig-out/`, in that order, fails on a reworded comment rather than on a
  lost upstream file, and passing it says nothing about upstream.  The
  append is recorded in `UPSTREAM.md` and `NOTICE.md` instead, `.gitignore`
  is named there as the single deliberate exception, and every other
  upstream source, header, test, script and licence path stays in the
  `git diff` list.
* The native job's second `zig build smoke`, which grepped the report for
  the version banner and two fixed phrases, is deleted.  The example already
  exits non-zero when a decoded upstream fixture disagrees with its input,
  so its exit code is the semantic check; the printed report is for a
  reader, not a contract.

## 12. Build-script and facade corrections from source reading

Every item below was found by reading Zig 0.16.0's own `lib/std` and this
fork's sources, or from a diagnostic the parent reported.  Nothing here has
been compiled, run, formatted or committed since, and no entry claims a gate
result.  The C library is untouched.

`build.zig`:

* The SIMD kernels' architecture field is `std.Target.Cpu.Arch`;
  `std.Target` has no `Arch` member in 0.16.
* `++` needs a comptime-known result length, so it cannot join a runtime
  value.  The generated `version.h`, the fixtures module name, the two
  install-path strings per header and the `-Dcheck-targets` help text are
  built with `b.fmt`; the target-name lists the help text and the failure
  message share come from the same tables the check walks, joined with
  `std.mem.join`.  The remaining `++` operands are literals.
* `addGeneratedHeaders` returns `files.getDirectory()`.  It returned the
  path of a placeholder file added beside the two real headers, and
  `htscodecs_config/` is a directory: the C sources search the returned path
  for a file named `config.h` and could not have found one.
* The installed-header proof compiles its two translation units from
  `files.getDirectory()` — `Step.WriteFile` has no `path` field — and takes
  its include path from `b.getInstallPath(.header, "")`.  `LazyPath` has no
  `custom` variant, and the header *directory* is what makes
  `<htscodecs/htscodecs_all.h>` resolve; the old code passed a file path.
* That proof no longer restates upstream's prototypes.  Three were already
  wrong against the headers this package installs: `hts_pack` takes five
  arguments, `arith_compress` orders `order` before `out_size`, and
  `tok3_encode_names` takes `int *out_len`, not `unsigned int *`.  A
  redeclaration that disagrees with the header is a compile error, and it
  proved nothing the header did not already prove.  Taking the address of
  the declared names keeps the proof: a name the installed headers do not
  declare is a compile error, a name the archive does not export is a link
  error.  The invented `htscodecs_proof_version` is replaced by
  `htscodecs_version`, which `htscodecs.h` declares and `htscodecs.c`
  defines.  `var_get_u32` and `fast_log` are taken with upstream's own
  return types, `int` and `double`.
* `addOneCheckTarget` passes the `bz2` decision to `addPublicModule`, so a
  cross-target translation cannot describe a different build from the
  archive it is compiled against.
* The provenance gate iterates `required_records`, the name its table
  actually has.
* The option documentation says `-fsys=htscodecs`, which is what
  `b.systemIntegrationOption` reads; it is fed by the build runner's
  `-fsys=`/`-fno-sys=` flags and never appears in the `-D` option map, so
  `-Dsystem=true` was never a mode this build had.

Facade:

* Aliasing is an ordinary comparison again.  `checkDisjoint` was a
  `std.debug.assert`, which vanishes in ReleaseFast and ReleaseSmall, while
  the module documentation promised `error.InvalidArgument` "in every build
  mode" and `Error.InvalidArgument` listed overlapping buffers.  It now
  returns that error before the call in every build mode, which is what the
  public contract claims and what `README.zig.md` now describes.
* `rle.encode` enforces the bound its own documentation states.  Upstream
  writes one literal per input byte into `out` (`rle.c:122`) and one
  unbounded `var_put_u32` per run into `run` (`rle.c:131`), checking
  neither, and the wrapper passed both through.  A run of length L costs at
  most L varint bytes, so `data.len` is the true bound for both buffers, and
  a shorter one is `error.BufferTooSmall` — a case `Error.BufferTooSmall`
  already promised and nothing implemented.
* Line citations in the docs that name an upstream write were corrected
  against the sources: the reverse-complement loop is
  `fqzcomp_qual.c:1086`-`:1101`, `hts_pack` writes the map code at
  `pack.c:68` and rejects the alphabet width at `pack.c:75`, and the
  `nsym == 1` copy is `pack.c:212-215`.
* `test/facade_contract_test.zig` gained a regression test for each of the
  two new refusals: overlapping buffers on both the encode and the decode
  side, and `rle.encode` one byte short of its documented bound.

## 13. Observed fixture, boundary and cross-target repairs

* Decode fqzcomp's raw scores with separate source and destination offsets;
  the independent quality oracle is upstream's column-one output conversion.
* Use each 32x16 order's own compression bound, preserve complete-name prefixes,
  and test the pack-map boundary with independent metadata. Reference all
  218 upstream fixture files.
* Report the single-symbol unpack copy's actual length. Release the damaged
  stream test's allocation. Correct the consumer fingerprint, remove its
  unused allocator argument, and size generated name records from the format.
* Compile SIMD objects with explicit, baseline-relative target features rather
  than `-m` C flags, without raising the scalar dispatcher's feature baseline.

Observed with Zig 0.16.0: Debug and ReleaseSafe each pass 38 tests; smoke matches
the upstream fixtures; the independent consumer exercises every facade codec
and raw C. The six-target compile/provenance gate passes 67 steps. Cross-target
binaries were not run. The default build has no libbz2 support and reports that
when its optional fixture is exercised; `zig build test -Dbz2=true` compiles the
optional bzip2 support and also passes 38 tests.

`zig build` installs the library, the example and the provenance gate in 15
steps, and `zig fmt --check` over the whole workspace exits zero.

