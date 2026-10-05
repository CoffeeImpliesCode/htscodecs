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

*(Superseded in one sentence by entry 15: `README.md` is now this fork's
README and upstream's bytes live at `README.upstream.md`.  Everything else in
this entry still describes the tree.)*

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


## 14. Zig API contract alignment — 2026-10-03

**Condition.** RLE indexes a 256-symbol table with a caller-supplied C count.
Zero requests encoder survey; negative and greater-than-256 counts are invalid.

**Fix.** Return `InvalidArgument` before encode/decode for those invalid
counts, preserving zero survey. Narrow `Slice.num_records` with the existing
checked helper. Document Owned alias/once-only release, actual guarded and
unguarded overlap pairs, Stripe destination size, mutable inputs and decoder
error/output contracts. Keep namespace documentation at owning declarations.
Use the actual `-fsys=htscodecs` option in authored records; the frozen header's
old option comment is not authoritative.

**Verification and bound.** Zig 0.16.0, native Linux x86-64: install,
tests in all four modes, smoke, package consumer and module example pass.
Compile-only `check` passes. Separate four-mode consumers check -1/257
rejection and unchanged outputs, zero survey and a 256-symbol round trip.
System-provider and optional bzip2 mode results are not refreshed here.
Native source, bridge headers and generated bindings are unchanged.


## 15. Contract migration — 2026-10-04

**README relocation.**  Upstream's `README.md` was preserved byte for byte as
`README.upstream.md` (sha256
`b77d87e58c92f1aae4e74f8071c589ae23d424da82d2d73fa8434525be22de26`, identical
on both paths at the moment of the move) and `README.md` became this fork's
own README: native-source deviations, native-build deviations with a dated
history link, the build/run/test matrix, consumption.  Entry 6's sentence
saying `README.md` is untouched is superseded by this entry and by nothing
else in it.  Following the bytes, the CI pinned-commit diff now lists
`README.upstream.md`, and `build.zig.zon` `.paths` carries the seven new
paths.

**Licence of the fork's own files.**  The owner authorized a per-project
licence for fork-authored additions.  `FORK-LICENSE.md` records the
authorization, the grant (BSD-3-Clause, matching upstream's primary terms),
the SPDX identifier `BSD-3-Clause`, the paths it covers and the paths it does
not.  The holder is the fork's contributors collectively; upstream authors are
not credited with fork work.

**`NOTICE.md` restructured into a per-file inventory.**  Upstream's terms are
reproduced as before, plus a table of which notice each file carries and
where.  Two facts now stated: the CC0 waiver text exists only at
`LICENSE.md:39-45`, not in `rANS_byte.h` or `rANS_word.h`, which carry a
one-line public-domain statement; and `c_range_coder.h:1-4` is a public-domain
dedication with a modification credit, not a waiver.

**Native delivery (NativeDelivery role).**

* `-Dlinkage=static|dynamic` selects the installed artifact.  The default is
  `static`, which is the policy this build already had:
  `std.Build.LibraryOptions.linkage` defaults to `.static` in the pinned
  toolchain and htscodecs never set it.
* The shared variant installs `libhtscodecs.so.2` with
  `DT_SONAME libhtscodecs.so.2`, or `libhtscodecs.2.dylib` on Darwin, or
  `htscodecs.dll` with an import library on Windows.  The `2.0.12` triple
  reproduces libtool's `-version-info 3:12:1` from `configure.ac`, whose ABI
  is `current - age` = 2; it is not the release version and
  `build.zig.zon` still says `1.6.7`.
* The per-ISA 32x16 objects are compiled PIC for the shared variant and not
  for the static one, so the static archive stays what it was.
* `zig build install` now also installs `lib/pkgconfig/htscodecs.pc`
  (`Version:` 1.6.7, `Libs.private:` always `-lm`, plus `-lbz2` only in a
  `-Dbz2=true` build) and the licence and documentation material under
  `share/licenses/htscodecs/` and `share/doc/htscodecs/`.  `build.zig` is the
  only thing that installs it; the Nix derivation copies nothing.
* `.gitignore`'s appended block also covers `zig-pkg/`, `result` and
  `result-*`, so a Nix build's output symlinks do not show up as untracked.
  Upstream's 47 entries are still untouched; entry 8 remains the record of
  the append.
* `zig build check` now links statically, and `zig build check-shared
  -Dlinkage=dynamic` is its counterpart against the shared graph: every
  module position independent, each target's shared object really linked, and
  on Windows the generated export definition resolved.  Neither of them runs
  a cross-target binary; both are compile-only.

**Standalone Nix packaging (this role).**

* `package.nix` is one uncurried, source-only function returning one
  derivation, with `linkage ? "static"` as the variant selector and
  `bzip2 ? null`.  No sibling import, no host path, no download.  Its install
  phase runs `zig build install -j"$NIX_BUILD_CORES" --prefix "$out"
  -Doptimize=ReleaseSafe -Dcpu=baseline -Dlinkage=<variant>` with both Zig
  caches under `$TMPDIR`, and the setup-hook phases are disabled so those are
  the only flags.  The build graph owns C flags, source lists, headers, the
  `.pc` file and the licence installs; the derivation copies nothing.
* `flake.nix` exposes `packages.<system>.{static,shared,default}` from the
  pinned nixpkgs input, `default = static`, and no devShell.
* `devenv.nix` keeps the shell to tools — Zig 0.16.0, pkg-config, bzip2 and
  its headers — and exposes lazy `outputs.static`, `outputs.shared` and
  `outputs.default` calling the same `package.nix`; `devenv build
  outputs.static` builds one.  Tasks are namespaced (`sdk:build`,
  `sdk:test`, …) and run real commands.
* Both entry points pass `bzip2 = null` explicitly, because `callPackage`
  fills an argument from the package set whenever a matching attribute
  exists and would otherwise enable the optional codec method.
* `flake.lock` and `devenv.lock` are the driver's to write.  Neither exists
  yet, so no flake build or devenv shell has been evaluated here.

**Status.** Every gate named in `README.md`'s matrix is `PENDING-VERIFICATION`
for this tree.  The 2026-10-03 receipts recorded in entry 13 and entry 14
describe the build as it stood before this entry, and are cited as historical
evidence of exactly that.  *(Superseded in one respect by entry 16, which
records the one matrix row that does carry a receipt for this tree.)*

## 16. Runtime loading, and the one declaration without an implementation — 2026-10-04

**Runtime route.**  `-Druntime=true` resolves the library's native symbols
through a generated dispatch instead of linking them.  It is orthogonal to
`-Dlinkage`: the C artifact is compiled and installed either way, because in
that configuration it is the provider the dispatch binds to rather than
something a consumer links.  The dispatch is generated from this build's own
translation step's output, so the set of names it asks for is target-derived
rather than a hand-maintained catalogue, and a provider compiled for a
narrower ISA set than the one this build was configured for is refused at
load instead of being used for the half of the library it does have.
`-Druntime=true` and `-fsys=htscodecs` remain mutually exclusive: system mode
publishes the installed library's own headers and has no translation of its
own to generate a dispatch from.

**The single exception, with its evidence.**  Exactly one name the installed
headers declare has no implementation at this pin:

* `rANS_static32x16pr.h:83`-`:86` declares `rans_compress_O0_32x16_sse4`
  under `HAVE_SSE4_1 && HAVE_SSSE3 && HAVE_POPCNT`, which
  `include/htscodecs_config.h:74`-`:90` derives from `__x86_64__` — so the
  declaration exists on `x86_64` and on no other configured target.
* The only definition upstream wrote is inside the `#if 0` block at
  `rANS_static32x16pr_sse4.c:113`-`:460`, immediately under upstream's own
  reason at `:111`-`:112`: "SSE4 implementation of the Order-0 encoder is
  poorly performing.  Disabled for now."

This fork leaves that `#if 0` as pinned.  Re-enabling it would be a
native-source modification and writing a replacement would be a different
library published under upstream's name, so neither is done; there is no
alias, no scalar stand-in, no facade method, no partial API and no
export-table entry for it.

**What that means for a caller, and what it does not mean.**

* Runtime-loaded: it is the single optional entry in the dispatch table
  (`runtime/graph.zig`, `provider_optional`).  A provider that does not
  export it still loads and every other codec works.  A call to it is refused
  by name — `htscodecs: the loaded provider does not export
  rans_compress_O0_32x16_sse4, which rans_compress_O0_32x16_sse4 needs; this
  provider is not the library this build describes` — an ordinary panic in
  every optimisation mode.  No substitute runs and no retry is attempted.
* Linked: there is no table, so a call is a direct reference to a name no
  object in the archive defines.  A program calling it must supply a real
  external definition of that exact name itself; this package manufactures
  none.  The generated Windows export definition for the shared variant is
  built from what each kernel source *defines*, so for the SSE4 kernel it
  names `rans_uncompress_O0_32x16_sse4` and `rans_uncompress_O1_32x16_sse4`
  and no encoder (`build.zig:142`-`:145`).  The earlier export list that
  named the SSE4 encoder is removed.
* The library's own kernel selection never needs the missing function, and
  that is upstream's code: the SSE4 branch of the *encoder* dispatcher
  returns the scalar kernel (`rANS_static4x16pr.c:1001`-`:1004` for order 0,
  `:987`-`:990` for order 1), while the *decoder* dispatcher does select the
  SSE4 decoders (`:1052`, `:1066`).

Every other declared name is implemented and required.  Counting the eleven
installed upstream headers gives 46 function declarations; the subset a
configuration exposes is 42 on `x86_64` — the four Neon declarations are
hidden there — 35 on `aarch64`, and 31 on `riscv64` and `wasm32`, and in each
of those sets every name but the one above has a definition this build
compiles.  This corrects a broader claim the earlier records carried in two
places: the required set is target-derived, and it is not "every declaration
the header set contains".

**Two source-reading findings recorded rather than silently fixed.**

* **Corrected — the stated reason beside the kernel export list named a
  declaration that does not exist.**  It read: upstream declares
  `rans_compress_O1_32x16_sse4` at `rANS_static32x16pr.h:93`.  It does not —
  line 93 declares `rans_uncompress_O1_32x16_sse4`, and no order-1 SSE4
  encoder is declared anywhere in that header.  The export list itself was
  always correct, since it is read out of what the kernel source defines;
  only the sentence giving the reason was wrong.  It now states the real one
  (`build.zig:121`-`:132`): the header declares three names under "Only the O0
  decoder for now" (`rANS_static32x16pr.h:81`) — the O0 encoder at `:83`-`:86`
  and the O0/O1 decoders at `:88`-`:96` — while `rANS_static32x16pr_sse4.c`
  defines only the two decoders, its O0 encoder sitting inside the `#if 0`
  block at `:113`-`:460`.  A list read off the declarations would therefore
  name `rans_compress_O0_32x16_sse4`, which no object this build compiles
  contains.  The `exports` list at `build.zig:147`-`:150` is unchanged and
  was never wrong.  A comment edit, so nothing about any artifact changes;
  it landed after the 2026-10-04 receipts in entry 17 below.
* **Withdrawn — the installed-header proof no longer references the undefined
  name.**  Its first translation unit used to take the address of
  `rans_compress_O0_32x16_sse4` under the same macros the header gates it on,
  which made `zig build headers` and `zig build headers-run` *expected to fail
  to link* on an `x86_64` configuration, and `README.md`'s matrix said so.  The
  proof now takes `rans_uncompress_O0_32x16_sse4` instead — defined at
  `rANS_static32x16pr_sse4.c:462`, and already in this build's own SSE4 export
  list at `build.zig:208`-`:211` — with that decoder's real signature, whose
  fourth parameter is `unsigned int` by value where the encoder's is
  `unsigned int *` (the reasoning in that entry's doc comment at `:147`-`:157`).
  A pointer to a name the archive defines is a proof; a
  pointer to one it does not was a link error dressed as one.  The expectation
  is now that the step links, and that is still a source-level reading only:
  nothing has been run since, so `README.md`'s row stays
  `PENDING-VERIFICATION` rather than green.  `FORK-NOTES.md` entries 30, 35
  and 36 carry the same withdrawal.

  The first bullet above is unaffected by this and is now closed too; see its
  own entry.

**Status and receipt.**  One row of `README.md`'s matrix carries a receipt
from this migration: `HTSCODECS_PROVIDER=<provider> zig build test
-Druntime=true -Dlinkage=static`, 6/6, exercising real compression in every
mode the library has and decoding upstream's checked-in fixtures through the
static provider.  Nothing else in that column has one.  The shared-provider
counterpart, the other two runtime/linkage combinations, all four optimisation
modes, the six-target compile-only `check` and `check-shared`, the
53-platform matrix, the Windows shared graph, the Nix and devenv surfaces,
system-library mode and the header steps all remain `PENDING-VERIFICATION`
for this tree.

## 17. A requested shared object is refused on a target with no dynamic linker — 2026-10-04

**Condition.**  `-Dlinkage=dynamic` names the artifact it will produce, and
this package's own cross matrix walks `wasm32-wasi`, whose
`std.Target.DynamicLinker.kind` is `.none` (`lib/std/Target.zig:2385`).  A
`.wasm` module has no dynamic linker and no loader that resolves a shared
object's imports at load time, so there is no shared htscodecs for that row
to be.

**Symptom, observed.**  The parent's `zig build check-shared -j8` over all
six targets exited 1 with 61/67 steps.  The five hosted rows — core,
facade, every test object and the example, each target's own shared object
really linked — passed.  The `wasm32-wasi` row failed first at the library
with `wasm-ld: warning: creating shared libraries, with -shared, is not yet
stable`, and then each of that row's five consumers failed separately with
`error: unrecognized file extension of parameter
'.../htscodecs-linked/o/.../htscodecs.wasm'`.  So the run emitted a `.wasm`
file that nothing can load and turned one platform boundary into five link
errors that named a file extension and said nothing about htscodecs.
Receipt `htscodecs-current-six-target-check-shared-2026-10-04T14-44-05.968751+00-00.json`
under the current-baseline evidence directory, 2026-10-04T14:44:05Z, exit 1,
187 s.  It is the run that produced this entry and it is not evidence about
the tree as it now stands.

**Fix.**  One predicate and one message, read at the two places the delivery
is decided:

* `targetCarriesSharedObject` asks `std.Target.DynamicLinker.kind` and
  returns `true` for `.windows` separately.  `.windows` is also `.none`
  (`lib/std/Target.zig:2380`) because a PE/COFF image has no interpreter
  path, not because Windows cannot load a DLL; collapsing the two would
  refuse this package's own `x86_64-windows-gnu` shared row.
* `sharedObjectRefusal` produces the text, unprefixed, so the configure-time
  panic and the failing check row cannot describe the boundary two different
  ways.
* `build()` refuses `-Dtarget=wasm32-wasi -Dlinkage=dynamic` at configure
  time, before any step exists for that target.
* `addOneCheckTarget` makes an unsupported row of the `check-shared` matrix
  an `addFail` step carrying the same text.  The row keeps its name in the
  matrix, nothing is built for it, nothing is substituted for it, and the
  other five rows are still compiled.  It is a step and not a panic because
  that branch is only reached for a target nobody named with `-Dtarget=`.

**What is deliberately unchanged.**  All six names stay in both matrices.
`zig build check` is a separate step and still walks `wasm32-wasi`
successfully.  `-Dlinkage=static`, the default, remains a full configuration
for every target including `wasm32-wasi`, and so does `-Druntime=true`,
which selects the dispatch and is orthogonal to the linkage either way.
`-fsys=htscodecs` is unaffected: there the installed library's linkage is
not this build's to choose, and the option was already ignored.  The hosted
shared rows are untouched.

**CI and the development shell.**  `.github/workflows/verify.yml`'s cross job
now requires `check-shared` to fail *for this reason* — the refusal text
naming `wasm32-wasi` — for both facade routes, and adds a separate step that
requires the five rows which can carry a shared object to compile for both
routes.  `devenv.nix` splits the same contract into two tasks, because one
task that always fails can no longer distinguish an expected refusal from a
hosted regression: `sdk:check-shared` narrows to the five hosted rows and
must exit 0, while `sdk:check-shared-wasi-refusal` narrows to `wasm32-wasi`,
requires a non-zero exit, and asserts the same four strings.  `sdk:check`
still walks all six statically.  A run that stopped failing, or that failed
for another reason, is a failure of that job or of that task.

**Status — observed.**  Seven runs on 2026-10-04, all from
`/vol/fob-vol7/mi19/gertullj/foundation-libs/htscodecs` with the Zig 0.16.0
compiler at
`/home/tmp2/gertullj/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/zig`,
each with `-j8`, `--cache-dir .../contract-physics-lua/htscodecs-linked`,
`--global-cache-dir .../contract-physics-lua/global` and
`--prefix .../contract-physics-lua/htscodecs-refusal-proof`.  Full receipts:
`local://foundation-htscodecs-refusal-verification-manifest.json`.

| Command | Exit | Result |
|---|---|---|
| `zig build check` | 0 | 66/66 steps, all six targets, `wasm32-wasi` included |
| `zig build check-shared -Dcheck-targets=x86_64-linux-gnu,aarch64-linux-gnu,aarch64-macos-none,x86_64-windows-gnu,riscv64-linux-gnu` | 0 | 59/59 steps |
| the same with `-Druntime=true` | 0 | 41/41 steps |
| `zig build check-shared` (all six) | **1** | 58/60 steps, one failed: the `wasm32-wasi` row, refused by name.  Five hosted rows compiled; no `htscodecs.wasm` was produced and no `unrecognized file extension` appears in the output |
| `zig build install -Dtarget=wasm32-wasi -Dlinkage=dynamic` | **1** | configure-time refusal before any step is created; the panic names `build()` in `build.zig` |
| `zig build test smoke -Druntime=false -Dlinkage=static` | 0 | 42 tests passed |
| `zig build test smoke -Druntime=false -Dlinkage=dynamic` | 0 | 42 tests passed |

The two exits of 1 are the requested outcomes, not failures of this change,
and neither claims a shared `wasm32-wasi` artifact: there is none.

**Scope, stated narrowly.**  All seven receipts were taken against the tree
as it stood at 15:41Z on 2026-10-04.  Four source corrections landed after
them and are therefore *not* covered by any row above: the installed-header
proof now names a defined decoder instead of the `#if 0` one, the fixtures
module was made private, the `devenv.nix` tasks were split to match this
entry's CI contract, and the comment beside the kernel export lists now gives
the real reason instead of citing a declaration that does not exist.  All
four need their own focused check.  `zig build headers` / `headers-run` in
particular is still `PENDING-VERIFICATION` and is still expected to link.

Everything else this entry listed as out of scope remains out of scope: the
other optimisation modes, `-Dbz2=true`, `-fsys=htscodecs`, the
`nix`/`devenv` packaging surfaces, the 53-platform matrix, and the
shared-provider `-Druntime=true` run.  `README.md`'s rows are updated to match
this section; no row claims more than its own command.

## 18. Two front ends for the aggregate, and an ISA kernel that was one architecture short — PENDING-VERIFICATION

**Condition.**  `include/htscodecs_all.h` is not a self-contained header.  It
reaches five libc headers -- `<stdint.h>` and `<stddef.h>` at `:93`-`:94`, and
through `utils.h:37-39` (`include/htscodecs_all.h:113`) `<string.h>`,
`<stdlib.h>` and `<math.h>` -- and `zig translate-c` parses C with **Aro**,
whose preprocessor has to understand all of them before its parser sees a
single htscodecs declaration.  Separately, the four 32x16 ISA kernels are
selected by a target test in the build graph, and a test that is narrower than
the kernel's own preprocessor guard leaves a cell linking against symbols its
dispatcher calls.

**Symptom, observed.**  From the parent's 53-platform run, not re-run here:
fifteen of the fifty-three published cells failed to translate this
repository's aggregate — nine NetBSD, five OpenBSD and `x86-windows` — and
every one of them was Aro's own read of that target's C library rather than
anything in htscodecs.  The other thirty-eight translated from the aggregate
as it stands.  In the same run, the `aarch64_be-linux` cell's native
dispatcher referenced `rans_{compress,uncompress}_O{0,1}_32x16_neon` while the
build graph had not put that kernel's object into the archive.

**Cause, confirmed in source.**  Four separate facts, none of them htscodecs':

* **NetBSD, one family.**  `__END_DECLS` is `__END_PUBLIC_DECLS`
  (`generic-netbsd/sys/cdefs.h:431-432`), and under the `#if
  __GNUC_PREREQ__(4, 0)` at `:408` that macro is framed in two `_Pragma`
  operators — `__BEGIN_PUBLIC_DECLS` at `:411-412` and `__END_PUBLIC_DECLS`
  at `:413`.  Every libc header the aggregate reaches closes a declaration
  block with it.
* **OpenBSD ILP32, three cells** — `arm-openbsd`, `powerpc-openbsd`,
  `x86-openbsd`.  Aro ships and prefers its own `<stddef.h>`, which typedefs
  `size_t` as `__SIZE_TYPE__`
  (`lib/compiler/aro/include/stddef.h:8`), while
  `generic-openbsd/sys/types.h:171-174` typedefs the same name as `__size_t`
  under a `_SIZE_T_DEFINED_` guard that Aro's header never sets.  The two
  spellings are `unsigned int` and `unsigned long` at 32 bits and the same
  type at 64, which is why the five 64-bit cells build and these three do
  not.
* **OpenBSD MIPS, two cells** — `mips64-openbsd`, `mips64el-openbsd`.
  `generic-openbsd/mips64/endian.h:32-41` `#error`s unless `__MIPSEL__` or
  `__MIPSEB__` is defined, and Aro's MIPS table gives all four MIPS
  architectures `__mips__` and `_mips` and nothing else
  (`lib/compiler/aro/aro/Compilation.zig:635-642`).
* **`x86-windows`, one cell.**  `any-windows-any/stdlib.h:717` includes
  `<malloc.h>`, and `any-windows-any/malloc.h:183-187` derives
  `_ALLOCA_S_MARKER_SIZE` from `_ARM_`, `_X86_`, `__ia64__`, `__x86_64` or
  `__aarch64__`; `_MarkAllocaS` (`:191-197`), `_malloca` (`:206-211`) and
  `_FreeAllocaS` (`:219-224`) then name it, and Aro emits `static __inline`
  bodies.  Aro defines `__x86_64` for `.x86_64`
  (`Compilation.zig:436-440`) and `__aarch64__` for the two AArch64 members
  (`:691-692`), which is why `x86_64-windows` and `aarch64-windows` are not
  in this list, and it defines `_X86_` nowhere at all, which is why
  `x86-windows` is.

The AArch64 BE cause is one enum member.  Zig 0.16 splits big-endian AArch64
into its own `std.Target.Cpu.Arch`, `.aarch64_be`
(`lib/std/Target.zig:1327-1328`), so a kernel test written as
`target.result.cpu.arch == .aarch64` is false there.  Clang defines
`__ARM_NEON` and `__aarch64__` for both members, so on the big-endian cell
the kernel body still compiles (`rANS_static32x16pr_neon.c:35`) and the scalar
dispatcher's Neon half still compiles (`rANS_static4x16pr.c:1072`) and returns
all four names (`:1112-1113`, `:1135-1136`).  The object was simply not in
the archive.

**Fix — the aggregate (fork build only).**  `build.zig` grows a private
`TranslationRoute` enum, a private `translationRoute(target, headers)`
(`build.zig:1208-1222`) consulted once per target, and a private
`preprocessedAggregate(b, target, bz2)` (`build.zig:1298-1331`).

* `.aro` on every target that translated before, reading
  `include/htscodecs_all.h` as it stands.  Unchanged for thirty-eight cells.
* `.preprocessed` on NetBSD, on the three ILP32 and two MIPS OpenBSD cells
  and on `.x86` Windows: `preprocessedAggregate` first runs
  `zig cc -E -dD -x c` — the compiler running the build script, so the same
  pinned one, with the same `-target` when the target is not native, the same
  `c_flags`, the same `-DHTSCODECS_WITH_BZ2=1` the translation already
  carried, and a `-MD`/`-MF` depfile through
  `addPrefixedDepFileOutputArg` — and Aro parses what that wrote.

Nothing is stubbed, narrowed, renamed or substituted, and no macro of the
compiler's own is predefined: the front end in front is the compiler that
compiles the C core, so `_X86_`, `__MIPSEL__`, `__MIPSEB__` and `__ARM_NEON`
are the ones the target really has.  The conditions are the property each
cause turns on — an OS tag, a pointer width, an arch member — so the next
architecture of a family is covered instead of another triple somebody has to
remember.  `-fsys=htscodecs` is excluded by construction and keeps Aro: it
reads the installed headers, no cell of the matrix reaches it, and no failure
of that aggregate has been observed.

**Fix — the ISA kernels (fork build only).**  `SimdKernel.arch` becomes
`SimdKernel.archs`, a list of `std.Target.Cpu.Arch`, and one predicate
`targetBuildsKernel` (`build.zig:261-266`) is the only thing that reads it.
`addCoreLibrary` (`:854`) and `addWin32ModuleDefinition` (`:914`) both call
it, so an export table and an object closure still cannot disagree.  The Neon
kernel's family is `.aarch64` and `.aarch64_be`; the three x86 kernels keep
the single member `.x86_64`, which is all the family can be.  `.armeb` and
`.thumbeb` are deliberately not members: they do not define `__aarch64__`, so
both the kernel (`rANS_static32x16pr_neon.c:1973-1975`) and the dispatcher
(`rANS_static4x16pr.c:1148`) take their scalar `#else` and no object is
needed.  The complete native closure is unchanged — ten scalar units and the
kernels the target's own guards compile — and nothing is dropped for any
target.

**Big-endian 32-bit Arm stays a native boundary.**  The `thumbeb-linux` cell
is not one of the fifteen and not one of the link failures above: it builds,
and what it reports is a mismatch in upstream's own codec output on
big-endian 32-bit Arm.  That is upstream's algorithm, in upstream's bytes, on
a platform `htscodecs/htscodecs_endian.h:78-88` explicitly claims to
support.  No `.c` and no `.h` upstream file is touched here, no test is
removed, skipped or weakened, and the cell is reported for what it is rather
than made to pass.  It is an explicit platform boundary, and the rule that
keeps it one is in `FORK-NOTES.md` entry 40.

**Status.**  `PENDING-VERIFICATION`.  No gate has observed this tree: the
fifteen translation failures and the `aarch64_be-linux` link failure above
are the parent's observations of the tree *before* these edits, and nothing
has been run since.  The runs that would move this entry are named in
`FORK-NOTES.md` entries 38 to 40.

**Not claimed, and not done here.**  `runtime/graph.zig`'s `libc_noise` list
was measured over Aro's translation for the cells that translated, which is
the thirty-eight; the fifteen cells that get the new front end have not had
their C-library declaration surface measured, and a name that surface adds
and the list omits would be routed rather than linked — a load-time refusal
under `-Druntime=true`, not a compile error.  `runtime/graph.zig` is the API
role's file and is not touched by this change; the measurement is theirs to
take.  `README.zig.md` and `README.md` carry no row for any of this yet.
Neither is `-Dbz2=true`, `-fsys=htscodecs`, the `nix`/`devenv` surfaces, the
optimisation modes other than the default, or any cell outside the published
matrix.

## 19. The devenv tasks build in the directory they name, and write nowhere else — 2026-10-04

**What was observed.**  The parent's Nix acceptance run of this SDK, on
2026-10-04, failed both devenv gates and neither reached a build.  Under the
canonical `devenv --from path:<sdk>` entry, `devenv tasks run --mode single
sdk:provenance` printed `error: no build.zig file found, in the current
directory or any parent directories`, and `devenv tasks run --mode single
consumer:run` printed `cd: consumer: No such file or directory`.  The logs are
`…-htscodecs-devenv-integrity.log` and `…-htscodecs-devenv-consumer.log`.  The
cause is not this repository: a task body runs with the *caller's* working
directory, and under that entry that directory is a scratch project holding
`devenv.lock` and `.devenv/` — none of `build.zig`, none of `consumer/`.

**What changed.**  `devenv.nix` only.  No `build.zig`, no `build.zig.zon`, no
`package.nix`, no `flake.nix`, no C source, no header, no test, no fixture, no
licence record and no task name moved.

* Four `let` bindings.  `sdkRoot = builtins.toString ./.` is this module's own
  directory — `./.` is the directory of the file that writes it, so it does not
  depend on where the caller stood, and `builtins.toString` rather than an
  interpolated `${./.}` keeps it a plain path string instead of asking Nix for
  a read-only store copy of the whole tree.  `sdkRootArg` is it through
  `lib.escapeShellArg`, which is this workspace's convention (`package.nix`
  uses the same function).  `inSdk` is `cd <that> || exit 1`, the first line of
  every one of the ten `exec` bodies; the `|| exit 1` is load-bearing, because a
  body that continued after a failed `cd` would build in, or check, whatever
  directory it happened to be standing in.
* `-j8` on all ten bodies, matching this workspace's job count.  Before this,
  two of the ten (`sdk:check-shared` and `sdk:check-shared-wasi-refusal`)
  carried it and eight did not.
* `--cache-dir` on all ten, always an external directory.  `zig build`'s
  default is `.zig-cache` beside the build root, which is this checkout, and a
  body that left it at that wrote a cache into a tree the driver compares
  before and after a run.
* `--summary all` on all ten.  Eight of the ten already carried it; the two
  that did not were `sdk:check-shared` and `sdk:check-shared-wasi-refusal`.
* The caches are resolved by the body itself, not by `enterShell`.
  `devenv tasks run --mode single` does not run the shell hook, so a body that
  assumed the hook had already set them ran on Zig's own default — which is how
  a task could still write `.zig-cache/` here even with a `cd` in front of it.
  `choosePaths` therefore resolves each of `ZIG_LOCAL_CACHE_DIR` and
  `ZIG_GLOBAL_CACHE_DIR` before the compiler is reached: a value the caller
  exported wins and is never overwritten, a missing one comes from
  `$XDG_CACHE_HOME` and then from `$TMPDIR`, and with neither set the body names
  what is missing and exits 1.  There is no `/tmp`, `/var/tmp`, Nix store path
  or in-tree fallback, and no new environment name is introduced for the caller
  to learn: these are the two variables Zig itself reads.  A caller's own
  `--cache-dir` at the end of its command line still overrides the explicit
  one, as it always did.
* `--prefix` on exactly two.  A bare `zig build` *is* the install step, so
  `sdk:build` installs and has to say where; and `consumer/build.zig:135-138`
  makes the consumer's `run` step depend on its own install step, so
  `consumer:run` installs for the same reason from the other side.  The other
  eight steps — `test`, `test -Doptimize=ReleaseSafe`, `smoke`, `check`,
  `check-shared`, the `wasm32-wasi` refusal, `headers-run` and `provenance` —
  depend on no install step (`build.zig:549-562`, `:985-994`, `:1047` and
  `:2145` hang work *off* the install step, never onto it), so none of them is
  given a prefix it would not use.
* Where the install prefixes go follows the same rule, decided in the same
  helper: `$ZIG_LOCAL_CACHE_DIR/htscodecs-prefix` for `sdk:build`, and
  `$ZIG_LOCAL_CACHE_DIR/htscodecs-consumer-prefix` for
  `consumer:run`, whose cache is `$ZIG_LOCAL_CACHE_DIR/htscodecs-consumer-cache`
  because `consumer/` is a separate package with a separate build graph.

**What did not change.**  The step names, the linkage each task selects, the
five-row `sdk:check-shared` narrowing and the four refusal strings
`sdk:check-shared-wasi-refusal` asserts are all as they were.  No body
forwarded caller flags before and none does now: `devenv tasks run` on 2.4
cannot pass arguments to a task, so a `"$@"` here would be a claim nothing
exercises.

**Status.**  `PENDING-VERIFICATION`.  Nothing in this entry has been run.  The
two failures quoted above are the parent's observations of this tree *before*
these edits; the run that would replace them is a devenv entry for this SDK
after the configuration freeze, and no claim about it is made here.

## 20. Packed output size is a caller contract, not an inspected argument — Debug/ReleaseSafe observations 2026-10-04

* `src/htscodecs.zig` and `README.zig.md` no longer promise
  `InvalidArgument` for an incorrect unpacked size in `pack.unpackTo`.
  Packed bits alone do not retain the original size. The caller supplies it;
  the facade does not reconstruct or validate it.
* Native packed-input length rejection returns NULL for `nsym` 8, 4 and 2
  (`htscodecs/pack.c:235-236`, `:269-270`, `:311-312`), which the facade maps
  to `OperationFailed`. The `nsym == 0` single-symbol path instead fills
  `out.len` bytes (`:335-337`); it does not reject a size mismatch. The
  existing `nsym == 1` copy-capacity guard remains `BufferTooSmall`.
* No native code, opaque-metadata validator or new API is introduced.
* **OBSERVED, bounded scope, 2026-10-04.** The parent's corrected native
  linked Debug consumer fixture used two symbols (`nsym == 8`), 128 packed
  bytes and an original size of 1024. Exact capacity wrote 1024 bytes and
  reproduced the input; capacity 4096 returned `OperationFailed`.
  Receipt:
  `/home/tmp2/gertullj/scratch/foundation-libs/text-contract-probes/htscodecs/epochs/after/hts-pack-corrected-after-debug/aggregate.json`.
  ReleaseSafe observed the same two results using the already-compiled
  artifact after the parent established identical executable SDK inputs
  and probe files. Receipt:
  `/home/tmp2/gertullj/scratch/foundation-libs/text-contract-probes/htscodecs/epochs/after/hts-pack-safe-artifact-reuse/aggregate.json`
  records `ARTIFACT_REUSED`, not a new compilation. The earlier full-closure
  setup failure remains unchanged: four documentation files had moved,
  not executable inputs. Loaded dispatch, other packed alphabets and
  cross-target behavior are not claimed.

## 21. fqzcomp boundary checks precede native indexing and sentinel arithmetic — focused observations 2026-10-04

* The strategy documentation now distinguishes the advertised
  `FQZ_MAX_STRAT` value 3 from the native five-row table. Row 4 is the
  custom row; indices at least 5 are clamped to it. The new guard is only
  `strat < 0`, returning `InvalidArgument` before native table access.
  No upper restriction is added.
* `qualStats` now narrows `num_records` before the `num_records + 1`
  capacity comparison, so an unrepresentable count returns `LengthOverflow`
  before that addition can overflow. The native struct reuses the narrowed
  count. The required extra `len` and `flags` entries remain unchanged.
* The sentinel documentation now cites the actual native selector-filter
  reads (`htscodecs/fqzcomp_qual.c:434-436`, `:533-534`) and makes clear
  that the extra entries are passed through unchanged.
* `test/facade_contract_test.zig` contains genuine negative-index and
  `maxInt(usize)` record-overflow regressions. The parent released both
  behavior edits after observing Debug before probes: the negative index
  aborted at native `fqzcomp_qual.c:770`, and the record count aborted on
  the facade's sentinel-capacity addition. Receipts are the
  `fqz-strat-negative/result.json` and `qual-stats-max-records/result.json`
  files under
  `/home/tmp2/gertullj/scratch/foundation-libs/text-contract-probes/htscodecs/epochs/before/hts-native-boundaries-before-3/`.
* **OBSERVED, bounded scope.** On 2026-10-04 the parent's native,
  statically linked external consumer (`-Druntime=false`) built with exit
  0 in Debug and ReleaseSafe. In each mode, `qual-stats-max-records`
  reported `LengthOverflow`, `fqz-strat-negative` reported
  `InvalidArgument`, and genuine compression/decompression controls at
  strategies 0, 1 and 5 reproduced all 68 original bytes. Strategy 5
  exercises the retained native upper clamp.
  Aggregate receipts:
  `/home/tmp2/gertullj/scratch/foundation-libs/text-contract-probes/htscodecs/epochs/after/hts-guards-after-debug-20261004/aggregate.json`
  and
  `/home/tmp2/gertullj/scratch/foundation-libs/text-contract-probes/htscodecs/epochs/after/hts-guards-after-safe-20261004/aggregate.json`.
* These five cases in two modes establish the focused consumer behavior,
  not loaded dispatch or cross-target coverage. Each complete probe driver
  exited 1 because its two pack cases used an invalid scratch fixture;
  those rows do not establish a pack facade defect. Entry 20 records the
  separate corrected Debug fixture observation.
* **Parent-observed SDK tests, 2026-10-04.** Native linked
  `zig build test -Doptimize=Debug -Druntime=false -j8 --summary all` and
  the same command with `-Doptimize=ReleaseSafe`, using the external
  `/home/tmp2/gertullj/cache/foundation-libs/contract-physics-lua/htscodecs-linked`
  local cache and
  `/home/tmp2/gertullj/cache/foundation-libs/contract-physics-lua/global`
  as global cache, each exited 0:
  19/19 steps and 44/44 tests, including 12/12 facade-contract tests and
  both new edge regressions. The fixture emitted its expected
  compiled-without-libbz2-support warning. This observation does not cover
  ReleaseFast, ReleaseSmall, loaded dispatch or cross targets.
  Durable command/count/exit evidence:
  `/home/tmp2/gertullj/scratch/foundation-libs/htscodecs-focused-native-tests-20261004.json`.
  No worker compiler, test or runtime probe ran.
* **Later native linked matrix, 2026-10-04.** The parent's eight htscodecs
  cells each ran `zig build test smoke install -Druntime=false -j8
  --summary all` with the mode/linkage selected explicitly: Debug,
  ReleaseSafe, ReleaseFast and ReleaseSmall, each static and dynamic.
  Every cell exited 0 with 44/44 tests and zero skips; static cells completed
  49/49 steps, dynamic cells 50/50. Smoke and install succeeded, with the
  expected archive or shared object present. Thus the two genuine edge
  regressions also executed in ReleaseFast and ReleaseSmall. Exact
  commands, external caches, fresh prefixes and per-cell receipts are in
  `/home/tmp2/gertullj/scratch/foundation-libs/native-final-evidence/contract-final-after-20261004/run.json`
  under its htscodecs rows. This supersedes the earlier optimization-mode
  limitation for native linked tests only; loaded dispatch and cross
  targets are still not claimed.

## 22. The private system-mode aggregate header establishes the standard types its public headers use — applied; not yet re-gated

* **Condition.**  An earlier positive system-library wave failed across its
  cells with fixed-width integer types and `size_t` undeclared in the
  translated surface.  The cause was in this fork, not upstream: the public
  upstream headers — `pack.h`, `rle.h`, `tokenise_name3.h`, `htscodecs.h` and
  the rest — carry no `#include` line at all, and this package's *private*
  aggregate header for that mode, `include/htscodecs_system.h`, reached them
  without establishing the types they use, so the translation saw
  `type specifier missing` on the first `uint8_t *`.  That file is private to
  the build: it is in neither `fork_headers` nor `upstream_headers` and is not
  installed.
* **Fix.**  That private aggregate header now includes the standard headers
  that declare those types — the `<stdint.h>` and `<stddef.h>` family — ahead
  of the installed `<htscodecs/...>` set.  The **native** aggregate header,
  `include/htscodecs_all.h`, is untouched by this change and already carried
  that same include set at `:93-94`; the defect and its fix are confined to the
  system-mode header.  The change lands together with the
  selected-platform-configuration fix and the removal of the empty shim.  No
  upstream C source, header, test, script or data file is touched, and the
  installed header set is unchanged.
* **Verification.**  **Applied; not yet re-gated.**  No receipt re-runs
  htscodecs after this fix, so nothing is promoted on its account and no
  earlier failing cell is recorded as a pass.  Specifically: the 53-target
  cohort `20261004T221720228710Z-45046` (receipt
  `htscodecs-53-target-8.json`; 18 runtime passes, 31 `build_only`, 2 runtime
  failures `aarch64_be-linux` and `thumbeb-linux`, 2 build failures
  `aarch64-netbsd` and `aarch64_be-netbsd`, driver exit 1) and the 2026-10-05
  compile-only baselines `20261005T014547Z-797a73f2`
  (`baseline-htscodecs-check` exit 0; `baseline-htscodecs-check-shared` exit 1
  on this build's own `wasm32-wasi` refusal, `58/60 steps succeeded`) all
  predate it, and the positive-system wave itself is not an all-PASS record.
  What would settle this entry is a fresh `zig build check`, a fresh
  `zig build check-shared`, a fresh 53-target matrix and a fresh loaded-cell
  run against this SDK after the fix.
