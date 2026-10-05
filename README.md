# htscodecs, packaged for Zig 0.16.0

A private downstream fork of
[samtools/htscodecs](https://github.com/samtools/htscodecs) pinned at tag
**v1.6.7** (`b9fc194f772e45bb0a1f44b08cbf8697a1384bae`), packaged for Zig
**0.16.0** with a standalone Nix surface.  The library is the real thing: all
the C sources under `htscodecs/` are compiled unmodified — rANS 4x8, rANS
4x16, the 32x16 SIMD kernels, the dynamic arithmetic coder, fqzcomp quality
scores, the read-name tokeniser, run-length coding and symbol packing.

One fact belongs in the first paragraph rather than a footnote.  One entry
point those sources *declare* has no implementation at this pin:
`rans_compress_O0_32x16_sse4`.  Upstream disabled it, this fork leaves it
disabled, nothing here substitutes for it, and no partial or stand-in API is
published in its place.  What that means for a linked call, for a
runtime-loaded call, for the Windows export definition and for what a
provider must supply is stated exactly under
[Native-build deviations](#native-build-deviations) and again under
[ABI facts worth knowing before you load it](#abi-facts-worth-knowing-before-you-load-it).

Upstream's own `README.md` is preserved byte for byte as
[`README.upstream.md`](README.upstream.md).  It documents the codecs and the
autotools build; it is not the entry point for this fork and nothing in it
was edited.

| Record | What it holds |
|---|---|
| [`README.upstream.md`](README.upstream.md) | upstream's README, unmodified |
| [`README.zig.md`](README.zig.md) | the Zig interface: namespaces, ownership, errors, aliasing, what the codec writes into your buffers |
| [`UPSTREAM.md`](UPSTREAM.md) | the pinned source, how it was obtained, how to verify and re-sync it |
| [`CHANGELOG.md`](CHANGELOG.md) | every divergence from upstream, numbered, newest first |
| [`NOTICE.md`](NOTICE.md) | upstream's terms, the per-file licence inventory, and what this fork adds |
| [`FORK-LICENSE.md`](FORK-LICENSE.md) | the licence of the fork-authored files and the authorization behind it |
| [`FORK-NOTES.md`](FORK-NOTES.md) | issues met while building this, each with cause and reusable rule |

## Native-source deviations

**None.**  No upstream C source, header, test, script, data file or licence
file is modified.  The upstream translation units are exactly those in
`htscodecs/Makefile.am` (`libhtscodecs_base_src`) plus the four per-ISA 32x16
kernels, and the 218 checked-in fixtures under `tests/dat` and `tests/names`
are embedded byte for byte.

"None" includes the one declaration without an implementation.  Upstream's
`#if 0` around `rans_compress_O0_32x16_sse4` is pinned source like every other
line of that file, so this fork does not re-enable it, and no fork-authored
source file stands in for it either.  The deviation recorded further down is
therefore about how this packaging *presents* that one name — required, or
optional, or absent from an export table — and not about a change to native
bytes.

Two upstream *paths* are not byte-identical, and neither is native code:

* `.gitignore` keeps all 47 of upstream's entries unchanged and appends a
  block for the build outputs `zig build` creates in Zig 0.16, later extended
  with `zig-pkg/` and the `result` symlinks a Nix build leaves behind
  ([`CHANGELOG.md`](CHANGELOG.md) entries 8 and 15).
* `README.md` was upstream's file until this migration.  Its bytes were
  preserved as `README.upstream.md` — sha256
  `b77d87e58c92f1aae4e74f8071c589ae23d424da82d2d73fa8434525be22de26`, the same
  value on both paths at the moment of the move — and this file took over the
  name.  [`NOTICE.md`](NOTICE.md) §5 is the record;
  [`CHANGELOG.md`](CHANGELOG.md) entry 15 is the change.

## Native-build deviations

The autotools build is left in place, untouched, and still works.  These are
the divergences in the Zig build that replaces it:

* **The build graph is `build.zig`**, not `configure` + `make`.  Nothing is
  downloaded at build time, no installed copy is used by default, and no
  upstream script runs.  The only generated files are `config.h` and
  `version.h`, which upstream's build also generates — the latter from
  `git describe --dirty` upstream, from the pinned tag here.
  (entries 1, 7)
* **Feature macros live in `include/htscodecs_config.h`**, decided by
  preprocessor conditionals on the target and read by both the C compilation
  and `b.addTranslateC`, so the archive and its translated interface cannot
  describe different builds.  On `wasm32-wasi` that selects upstream's own
  `NO_THREADS` fallback, because wasi-libc declares pthreads it does not
  implement.  (entry 2)
* **The per-ISA 32x16 kernels are separate objects**, compiled at baseline
  plus their own explicit feature sets so the scalar dispatcher never picks up
  AVX code, exactly as upstream's libtool convenience libraries do it.  They
  are compiled PIC only for the shared variant, so the static archive stays
  what it was.  (entries 3, 13)
* **`-Dbz2=true` is the only way to get bzip2**, which is what upstream does
  on a machine without libbz2.  It is off by default and nothing here turns it
  on implicitly.  (entry 4)
* **`-Dlinkage=static|dynamic` selects the installed artifact.**  The default
  is `static`, which is what this build did before the option existed:
  `std.Build.LibraryOptions.linkage` defaults to `.static` and htscodecs'
  `build.zig` never set it.  (entry 15)
* **A requested shared object is refused on a target with no dynamic
  linker.**  `-Dlinkage=dynamic` for `wasm32-wasi` — whose
  `std.Target.DynamicLinker.kind` is `.none` (`lib/std/Target.zig:2385`) —
  stops at configure time naming the target and the reason, and inside
  `zig build check-shared` that one matrix row becomes a failing step
  carrying the same text while the other five rows are still compiled.  No
  static archive is substituted and no row is dropped.  Windows is the one
  `.none` that still carries a shared object (`:2380` — a PE/COFF image has
  no interpreter path, and its imports are resolved by the loader inside the
  OS), so `x86_64-windows-gnu` keeps its shared row.  (entry 17)
* **A Zig facade over the translated C**, namespaces `rans4x8`, `rans4x16`,
  `rans32x16`, `arith`, `fqzcomp`, `rle`, `tok3` and `pack`, plus embedded
  fixtures so the tests need no file system.  (entry 5)
* **CI points at this fork's own workflow.**  The Cirrus and AppVeyor
  workflows drive the build on the upstream maintainer's infrastructure and
  describe a build this fork does not use.  (entry 6)

* **Exactly one declared entry point has no implementation at this pin, and
  it is named here rather than described as a general caution.**
  `rANS_static32x16pr.h:83`-`:86` declares `rans_compress_O0_32x16_sse4`
  under `HAVE_SSE4_1 && HAVE_SSSE3 && HAVE_POPCNT`.  The only definition
  upstream wrote is textually present but not compiled: it is inside the
  `#if 0` block at `rANS_static32x16pr_sse4.c:113`-`:460`, immediately under
  upstream's own reason at `:111`-`:112` — "SSE4 implementation of the
  Order-0 encoder is poorly performing.  Disabled for now."  Nothing here
  supplies one: no scalar stand-in, no alias, no export-table entry, no
  facade method, and no partial API that covers some of what it would have
  done.

  The rest of the declared surface is real and required, and the claim is
  scoped rather than general.  The eleven upstream headers this package
  installs declare 46 functions in total.  Which of them a configuration
  actually exposes is target-derived — the SSE4 trio is gated at
  `rANS_static32x16pr.h:82`, AVX2 at `:101`, AVX512 at `:125`, Neon at
  `:149`, and the three x86 sets come from `__x86_64__` alone
  (`include/htscodecs_config.h:74`-`:90`).  So `x86_64` exposes 42
  declarations, `aarch64` 35, `riscv64` and `wasm32` 31.  Of each of those
  sets, every declaration except the one above has a definition that this
  build actually compiles, and every one of them is required: the scalar
  32x16 quartet, both SSE4 *decoders* (`rANS_static32x16pr_sse4.c:462` and
  `:1030`, which the decoder dispatcher really does select at
  `rANS_static4x16pr.c:1052` and `:1066`), all four AVX2 kernels, all four
  AVX512 kernels and all four Neon kernels.  A provider compiled for a
  narrower ISA set than this build was configured for is refused at load,
  not half used.  (entry 16)

  The library's own kernel selection never reaches for the missing encoder,
  and that is upstream's own code rather than this fork avoiding it:
  `rANS_static4x16pr.c:1001`-`:1004` is the order-0 SSE4 encoder branch and
  it returns the *scalar* `rans_compress_O0_32x16`, and `:987`-`:990` is the
  order-1 branch, returning the scalar `rans_compress_O1_32x16`.  Upstream
  gates the tier but hands it the scalar kernel, so an SSE4-only machine
  encodes with the scalar code and never forms the missing reference.
* **`-Druntime=true` resolves the native symbols through a generated
  dispatch** instead of linking them, and is orthogonal to `-Dlinkage`: the C
  artifact is compiled and installed either way, because in that
  configuration it is the provider the dispatch binds to rather than
  something a consumer links.  The dispatch asks for exactly the set above
  — the target-derived declarations this build's own translation produced —
  with one exception: `rans_compress_O0_32x16_sse4` is the single optional
  entry (`runtime/graph.zig`'s `provider_optional`).  Its absence does not
  fail a load; a call to it stops the process by name.  (entry 16)

Each item is numbered and explained in [`CHANGELOG.md`](CHANGELOG.md); the
dated history of this migration is its entries 15, 16 and 17, all
**2026-10-04**.

## Build, run and test matrix

A row is only as good as the receipt in it.  Several are still
`PENDING-VERIFICATION`.  One group carries the refusal verification of
2026-10-04, each of its receipts narrow on purpose; the 2026-10-04 and
2026-10-05 cohort receipts are integrated at the end of this section, each
with what it does and does not prove.

* **The static six-target matrix**: `zig build check` exited 0 with 66/66
  steps, all six targets including `wasm32-wasi`.
* **The shared matrix**: `zig build check-shared` exited 1, and the exit 1
  *is* the result that was asked for — the `wasm32-wasi` row is refused by
  name.  Narrowed to the five rows that can carry a shared object it exits 0
  (59/59 steps), and the same five with `-Druntime=true` exit 0 (41/41).
  Nothing here claims a shared `wasm32-wasi` artifact: there is none, and
  `zig build install -Dtarget=wasm32-wasi -Dlinkage=dynamic` stops at
  configure with the same reason.
* **The host in both linkages**: `zig build test smoke` exited 0 with 42
  tests passed under `-Dlinkage=static` and again under `-Dlinkage=dynamic`.
  The one runtime receipt from the earlier migration is unchanged and stays
  the only `-Druntime=true` *run*; the `-Druntime=true` result above is a
  compile-only matrix, because `check` runs nothing.

Those receipts were taken against the tree as it stood at 15:41Z on
2026-10-04.  Four source corrections landed after them and are therefore not
covered by any row below: the installed-header proof now names a defined
decoder, the fixtures module was made private, the development-shell tasks
were split to match the shared-graph contract, and the comment beside the
kernel export lists now gives the real reason instead of citing a
declaration that does not exist.  Each needs its own focused check.  The
2026-10-03 receipts further down are historical evidence of the
pre-migration build, not of this tree.

A receipt is a receipt for the commands it names and nothing wider.  Three
things that once sat on that not-claimed list carry receipts of their own now,
each with its own stated scope below: every runtime/linkage combination in all
four optimisation modes (the three eight-cell waves), the published 53-platform
matrix, and a compatible *external* provider.  Still claimed by no row: a
shared `wasm32-wasi` artifact, because there is none to build; the Nix-fetched
consumer; `-Dbz2=true`; `provenance-history`; and any cell that was compiled
but never executed.

| Command | What it does | Last observed | Now |
|---|---|---|---|
| `zig build` | install the library, the 13 public headers, the example, `htscodecs.pc`, and the licence and documentation material | installed library, example and provenance gate in 15 steps, 2026-10-03 (`CHANGELOG.md` entry 13) — *before* the pkg-config and licence installs existed | PENDING-VERIFICATION |
| `zig build test` | the behavioural tests for the host target | 38 tests passed in Debug and again in ReleaseSafe, 2026-10-03 (entries 13, 14).  Superseded for Debug by 42 tests passed under `-Dlinkage=static` and again under `-Dlinkage=dynamic`, exit 0, 2026-10-04 (entry 17).  Then the 2026-10-04 eight-cell native linked matrix (entry 21): `zig build test smoke install -Druntime=false` with the mode and linkage named explicitly — Debug, ReleaseSafe, ReleaseFast and ReleaseSmall, each static and dynamic — 44/44 tests and zero skips in every cell, exit 0 in all eight (epoch `20261004T233628757747Z-69351`) | OBSERVED — the host in all four optimisation modes and both linkages, linked and loaded.  Cross-target runs are the 53-target row's business and are counted there, not here |
| `zig build test -Dbz2=true` | the same with the arithmetic coder's bzip2 method compiled in | 38 tests passed, 2026-10-03 (entry 13) | PENDING-VERIFICATION |
| `zig build smoke` | run the example, which checks its decoded fixtures against their inputs and exits non-zero on any disagreement | passed, 2026-10-03 (entries 13, 14).  Passed again with exit 0 under both `-Dlinkage=static` and `-Dlinkage=dynamic`, 2026-10-04 (entry 17).  Then 24 cells: three eight-cell waves, `smoke success` and the selected archive or shared object present in every cell (epochs `20261004T233628757747Z-69351`, `20261004T232823091897Z-23133`, `20261004T233121760876Z-12541`) | OBSERVED — the host in all four optimisation modes and both linkages, linked and loaded |
| `zig build headers`, `zig build headers-run` | compile, and run, two C translation units that each include the *installed* aggregate header | not separately recorded.  This row also used to carry a source caveat — the first unit took the address of `rans_compress_O0_32x16_sse4`, which this archive does not define, so an `x86_64` link was expected to fail.  It does not any more: the proof now names `rans_uncompress_O0_32x16_sse4`, which the SSE4 kernel really defines, so there is no expected link error left to explain here.  Nothing has been run since, so the row is unverified and not green | PENDING-VERIFICATION |
| `zig build check` | compile the core, the translated interface, every public facade method, the tests and the example for the six-target matrix, linked statically; nothing is executed | 67 steps passed, 2026-10-03 (entries 13, 14).  66/66 steps, exit 0, 2026-10-04 (entry 17).  Whole-graph compile-only baseline `baseline-htscodecs-check`, exit 0, `Build Summary: 66/66 steps succeeded`, `failed: false`, all six targets seen, no diagnostic line and no test line anywhere in the output (epoch `20261005T014547Z-797a73f2`) | OBSERVED — all six rows, `wasm32-wasi` included.  The 2026-10-05 baseline is compile-only and says so on its face: `runtime_pass_claimed: false`, so it is not a sixth test receipt and adds no runtime evidence |
| `zig build check-shared` | the same compile-only matrix against the shared graph: every module position independent, each target's shared object really linked, and on Windows the generated export definition resolved.  `-Dlinkage` does not select this step; it always walks the shared graph, so `check-shared -Dlinkage=dynamic` is the same command | three receipts, 2026-10-04, all against the tree as it stood at 15:41Z.  Narrowed to the five rows that can carry a shared object (`-Dcheck-targets=` naming them): exit 0, 59/59 steps.  The same five with `-Druntime=true`: exit 0, 41/41 steps.  The whole matrix: **exit 1, 58/60 steps, one failed** — the `wasm32-wasi` row, refused by name with `error: htscodecs: check-shared row wasm32-wasi: … DynamicLinker.kind is .none for that OS …`, and the five hosted rows compiled.  Earlier the same command exited 1 with 61/67 because that row instead built an unloadable `.wasm` and took five downstream consumers down with it (entry 17).  Whole-graph compile-only baseline `baseline-htscodecs-check-shared`, 2026-10-05: **exit 1, `failed: true`, `Build Summary: 58/60 steps succeeded (1 failed)`**, all six targets seen and none missing, the same single `check-shared` step on `wasm32-wasi` failing with the same refusal text, and an empty prefix inventory (epoch `20261005T014547Z-797a73f2`) | OBSERVED — the refusal, and the five hosted rows in both facade routes.  This is **not** a claim that a shared `wasm32-wasi` artifact builds: there is none, and none is claimed.  The exit 1 is that refusal, deliberately, inside a compile-only baseline (`runtime_pass_claimed: false`): it is not a compiler failure, not a regression, and not a runtime result |
| `zig build provenance` | the source-integrity gate: the licence and provenance records are present.  Offline, no git | part of every ordinary `zig build` | PENDING-VERIFICATION |
| `zig build provenance-history` | the pinned upstream commit is still in this clone's history.  Needs git; fails rather than reporting a success it did not observe | — | PENDING-VERIFICATION |
| `zig build -Dlinkage=dynamic` | the shared library, its `SONAME`, the generated export table on Windows | did not exist before entry 15.  Every dynamic cell of the three eight-cell waves installed and linked the shared object under its own prefix (entry 21 and the two waves below) | OBSERVED — the shared artefact and its installation in all four optimisation modes.  Still not claimed for `wasm32-wasi`, which has no dynamic linker |
| `cd consumer && zig build run` | a separate package that depends on this one through `b.dependency()` | passed, 2026-10-03 (entries 13, 14) | PENDING-VERIFICATION |
| `zig build test -fsys=htscodecs` | decode upstream's fixtures with an *installed* libhtscodecs, translating the installed headers | not refreshed in the previous wave (entry 14 says so).  The 2026-10-04/05 external-provider waves did **not** use this row: they went through `-Druntime=true` with the provider named by `HTSCODECS_PROVIDER`, so they are evidence for the loaded route and not for system-library mode | PENDING-VERIFICATION |
| `HTSCODECS_PROVIDER=<provider> zig build test -Druntime=true -Dlinkage=static` | the same behavioural tests with every native symbol resolved through the generated dispatch at run time: no native library is linked into the test binary, and the provider the variable names is the one the table binds to | did not exist before entry 16.  Then 6/6 on 2026-10-04, then 8/8 in each of two eight-cell waves: epoch `20261004T232823091897Z-23133` against this tree's own source-built provider, and epoch `20261004T233121760876Z-12541` against the accepted external `/usr/lib64/libhtscodecs.so.2.1.4` — every cell `Build Summary: 50/50 steps succeeded; 44/44 tests passed`, `skip_sites: []`, exit 0 | OBSERVED — 16 loaded cells across four optimisation modes, in two independent providers.  The external one is genuine independent external coverage; the own one proves the loaded route and nothing about a foreign library.  Cross targets, `-Dbz2=true`, and any third provider are not claimed by either wave |
| `HTSCODECS_PROVIDER=<provider> zig build test -Druntime=true -Dlinkage=dynamic` | the same, against a shared provider | did not exist before entry 16.  Then the same two eight-cell waves, dynamic half: 8/8 own-loaded and 8/8 external, 44/44 tests and zero skips in each, exit 0 | OBSERVED — 16 loaded cells, four optimisation modes, both providers, all PASS.  No other mode, target or linkage combination is claimed by them |
| `nix build .#static`, `nix build .#shared` | the two packaging variants | did not exist before entry 15 | PENDING-VERIFICATION |
| `devenv shell` | the canonical development shell: tools and tasks, not a built SDK | did not exist before entry 15 | PENDING-VERIFICATION |
| `devenv build outputs.static`, `outputs.shared` | build either packaging variant from inside the shell, through the same `package.nix` | did not exist before entry 15 | PENDING-VERIFICATION |

Options: `-Dlinkage=`, `-Druntime=true`, `-Dbz2=true`, `-Dcheck-targets=<list>`,
`-Doptimize=`, `-Dtarget=`, and `-fsys=htscodecs` for system-library mode.
That last one is not a `-D` option: `b.systemIntegrationOption` is fed by the
build runner's `-fsys=`/`-fno-sys=` flags, so `-Dsystem=true` is an unknown
option rather than a mode.  (`CHANGELOG.md` entry 12 corrects the stale
comment in `include/htscodecs_system.h` that says otherwise.)

`-Druntime=true` and `-fsys=htscodecs` cannot be given together: `build.zig`
refuses the pair before any step runs, because system mode publishes the
installed library's own headers through a linked shim and has no translation
of its own to generate a dispatch from.  `HTSCODECS_PROVIDER` names the
provider a test run should load; `test/provider.zig` is the only thing that
reads it, and there is no default location, no search path and no fallback to
a system library.

`zig build check` compiles for `x86_64-linux-gnu`, `aarch64-linux-gnu`,
`aarch64-macos-none`, `x86_64-windows-gnu`, `riscv64-linux-gnu` and
`wasm32-wasi`, and builds `aarch64-macos`, `x86_64-macos` or
`aarch64-windows-gnu` when they are named explicitly with
`-Dcheck-targets=`.  Cross-target tests are compiled, never run: `check` emits
them as objects.  A foreign compile is `build_only`, not a passing test.

`zig build check-shared` walks those same six names against the shared graph,
and one of them is refused rather than built.  `wasm32-wasi` has no dynamic
linker, so the shared htscodecs that row would produce is a file nothing can
load: `wasm-ld` warns that `-shared` is "not yet stable" for wasm, and every
consumer that then links the resulting `htscodecs.wasm` fails with
`unrecognized file extension`.  That row is now a named failing step inside
`check-shared` carrying the reason; the other five rows are still compiled,
`check` is a separate step that still walks all six, and `-Dlinkage=static`
— the default — is a full configuration for every target, `wasm32-wasi`
included.  `-Dtarget=wasm32-wasi -Dlinkage=dynamic` stops at configure time
with the same text rather than producing a partial tree.

That boundary is observed, not asserted.  2026-10-04, `zig build check-shared
-j8` over all six rows exited 1 with exactly one failure, the refusal:

The text is the build's own, re-wrapped here; it is printed as one line:

```
error: htscodecs: check-shared row wasm32-wasi: -Dlinkage=dynamic was requested
for wasi, whose OS has no dynamic linker (std.Target.DynamicLinker.kind is
.none for that OS), so no shared object can be built or loaded for it. This
build does not substitute a different artefact for the one that was asked
for; build the static delivery for this target instead, which is the
default. No artifact was built for this row, and nothing was substituted
for it.
```

58/60 steps, five hosted rows compiled, no `htscodecs.wasm` produced and no
`unrecognized file extension` anywhere in the output.  The same day
`zig build install -Dtarget=wasm32-wasi -Dlinkage=dynamic` stopped at
configure with that text before creating a step (exit 1), and
`zig build check` over all six rows exited 0 with 66/66 — so the static
delivery for that target is untouched.  See `CHANGELOG.md` entry 17.

The published 53-platform cross-test matrix is a driver-run gate over this same
tree, and it has now been run: epoch `20261004T221720228710Z-45046`, receipt
`htscodecs-53-target-8.json`, `jobs 8 / build-jobs 8`, `source_unchanged: true`,
`jobs_honoured: true`.  Of its 53 targets **18 are runtime passes** — each one
reporting `tests=44`, `reason=tests_complete` — **31 are `build_only`**, which
means the target compiled and its binaries were never executed because no runner
exists for it — and **4 fail**, so the driver exits 1.  Those four are two
different failures and are kept as two:

* **Runtime failures** (`reason=tests_failed`, run exit 1, 44 tests reported):
  `aarch64_be-linux` and `thumbeb-linux`.  Both build, link and execute; what
  they report is the codec's own output disagreeing with the reference bytes.
* **Build failures** (`reason=build_failed`, build exit 1, run never reached —
  `run.status: not_run`): `aarch64-netbsd` and `aarch64_be-netbsd`.

A build failure is not a runtime failure and a runtime failure is not a missing
binary, so neither class is folded into the other.  And because `build_only` is
compiled-but-not-run, "53 targets built" is not "53 tests passed": this cohort's
honest summary is 18 runtime passes, 31 compiles with no runner, and 4 failures
of two distinct kinds.

Two whole-graph baselines were taken the next morning, epoch
`20261005T014547Z-797a73f2`, and both are **compile-only** — each carries
`runtime_pass_claimed: false`, so neither yields a runtime result under either
exit code:

* `baseline-htscodecs-check` — exit 0, `failed: false`,
  `Build Summary: 66/66 steps succeeded`, all six targets seen, and not one
  diagnostic line or test line in the whole output.
* `baseline-htscodecs-check-shared` — **exit 1, `failed: true`**,
  `Build Summary: 58/60 steps succeeded (1 failed)`, all six targets seen
  (`x86_64-linux-gnu`, `aarch64-linux-gnu`, `aarch64-macos-none`,
  `x86_64-windows-gnu`, `riscv64-linux-gnu`, `wasm32-wasi`) and none missing.
  The single failing step is `check-shared` on `wasm32-wasi`, and its diagnostic
  is this build's own refusal, quoted above.  That is the *intended* outcome of a
  shared walk that includes a target with no dynamic linker: an explicit,
  named refusal inside a compile-only baseline, which is why the row exits 1.
  It is not a compiler failure, not a regression and not a runtime result; the
  prefix inventory is empty, because nothing was installed.

Three eight-cell waves then ran the tests themselves.  Every cell in each wave
is a runtime pass; none of the three is a compile-only row:

* **Native, linked** — `-Druntime=false`, epoch `20261004T233628757747Z-69351`:
  **8/8 pass**.  Debug, ReleaseSafe, ReleaseFast and ReleaseSmall, each static
  and dynamic, 44/44 tests and zero skips in every cell, `smoke` and `install`
  succeeding, exit 0 throughout (entry 21).
* **Own-loaded** — `-Druntime=true` with the provider this tree built itself,
  epoch `20261004T232823091897Z-23133`: **8/8 pass**, the same four modes and
  both linkages, every cell `Build Summary: 50/50 steps succeeded; 44/44 tests
  passed`, `skip_sites: []`, exit 0.  Independence here is `own`: the provider
  is this repository's own output, so this wave proves the loaded route and
  says nothing about a foreign library.
* **Independent external provider** — `-Druntime=true` with
  `HTSCODECS_PROVIDER=/usr/lib64/libhtscodecs.so.2.1.4` (sha256
  `55f11ac88673ba6c0af07e614fb6a1d9e6344c62781918c8f8a21a20a3035882`), epoch
  `20261004T233121760876Z-12541`: **8/8 pass**, every cell
  `Build Summary: 50/50 steps succeeded; 44/44 tests passed`, `skip_sites: []`,
  exit 0.  That provider was accepted as `kind: compatible-external` on route
  `path-02-libhtscodecs.so.2.1.4-success` (producer receipt
  `htscodecs-index.json`, epoch `20261004T232439Z`), so these 8 cells are
  genuine independent external coverage: 44 tests each, executed against a
  library this repository did not build.  The two loaded waves are visibly
  different libraries and not two names for one: this tree's own provider
  prints `htscodecs 1.6.7` in the smoke banner, the external one prints
  `htscodecs 1.6.0`.  The candidates refused in the same acceptance run were
  libraries that do not export this surface (`libbz2`, `libz`) and this
  tree's own unversioned `libhtscodecs.so` name, which is `independence: own`
  rather than external.

One change in the current graph is **applied and not yet re-gated**.  An earlier
positive system-library wave failed with fixed-width / `size_t` undeclared in the
translated surface, because this fork's own private aggregate header for that
mode left those types undeclared.  The fix is that the private aggregate header
now includes the standard headers that declare them — the `<stdint.h>` and
`<stddef.h>` family, in `include/htscodecs_system.h` — while the native
aggregate header `include/htscodecs_all.h` is untouched and already carried that
include set; it lands together with the selected-platform-configuration fix and
the removal of the empty shim.  **No receipt re-runs htscodecs after this fix.**
It is recorded here as applied with verification pending, and nothing above is
promoted on its account: the 53-target result predates it, the two baselines
predate it, and no cell of any wave is restated as a pass because of it.  What
would settle it is a fresh run of this SDK's own gates — `check`,
`check-shared`, the 53-target matrix and the loaded cells — after the fix.

## Consumption

### As a Zig dependency

```zig
// build.zig.zon
.dependencies = .{
    .htscodecs = .{ .path = "../htscodecs" },
},

// build.zig
const dep = b.dependency("htscodecs", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("htscodecs", dep.module("htscodecs"));
```

The module already links the library artifact, so the snippet needs nothing
else.  Two interfaces come with it: `htscodecs.c` is the translated C, which
carries every declaration the installed headers expose to this configuration
and hides none of them, and the namespaces are the convenience layer over it.
That is a statement about *declarations*, and the distinction matters here:
exactly one of those declarations, `rans_compress_O0_32x16_sse4`, has no
implementation at this pin, so `htscodecs.c` exposes a name that cannot be
called successfully.  It is named and its two consequences are spelled out
under [ABI facts worth knowing before you load it](#abi-facts-worth-knowing-before-you-load-it);
nothing partial is published in its place.

In a `-Druntime=true` build the same nominal module is the generated
dispatch rather than the raw translation: the names, types and constants are
the translation step's own, but each function reaches the library through
the table `htscodecs.load` fills.  `htscodecs.runtime_loaded` is a comptime
constant, so a consumer can write both configurations and have only the one
it chose analysed.
[`README.zig.md`](README.zig.md) is the interface documentation: ownership,
errors, aliasing, the inputs the codec writes into, kernel selection and the
optional bzip2 method.  `consumer/` in this repository is a real separate
package doing exactly the above.

### As an installed C library

`zig build install --prefix <dir>` (or `nix build .#static` / `.#shared`)
produces:

```
<dir>/include/htscodecs/*.h          13 headers: the aggregate, the config
                                     header, and the 11 upstream headers whose
                                     symbols this build compiles
<dir>/lib/libhtscodecs.a             static, the default
<dir>/lib/libhtscodecs.so.2          shared, with DT_SONAME libhtscodecs.so.2
<dir>/bin/htscodecs-demo             the example, self-checking
<dir>/lib/pkgconfig/htscodecs.pc     Version 1.6.7, Libs.private: -lm,
                                     plus -lbz2 only in a -Dbz2=true build
<dir>/share/licenses/htscodecs/      LICENSE.md, NOTICE.md, UPSTREAM.md,
                                     FORK-LICENSE.md
<dir>/share/doc/htscodecs/           CHANGELOG.md, README.md, README.zig.md,
                                     FORK-NOTES.md
```

`include/htscodecs_system.h` is deliberately *not* installed: it exists only
for system-library mode, where the headers come from the installation being
linked rather than from this tree.

The installed headers are a unit.  `htscodecs_all.h` reaches each upstream
header by relative path and `htscodecs_config.h` by bare name from the same
directory, so the directory is what makes `<htscodecs/htscodecs_all.h>`
resolve; `zig build headers` compiles two translation units against the
installed tree precisely because one translation unit cannot show that.

### ABI facts worth knowing before you load it

* **Two allocator families, and the boundary matters.**  Every buffer upstream
  returns to a caller — from `rans_compress`, `tok3_encode_names`,
  `hts_rle_encode`, `fqz_compress` and the rest — comes from libc `malloc`, so
  the caller releases it with `free`.  `htscodecs_tls_alloc`,
  `htscodecs_tls_calloc` and `htscodecs_tls_free` (`htscodecs/utils.h:66-68`)
  are a *separate* exported family for internal scratch: with pthreads they
  recycle through a per-thread pool keyed by a `pthread_key_t` created under
  `pthread_once` (`htscodecs/utils.c:103-135`), and `htscodecs_tls_free`
  decides pool-versus-heap by querying that key.  A pointer produced on one
  side must therefore be released by the library on the other; handing one to
  libc `free` is not equivalent.  Under `NO_THREADS` — selected for
  `wasm32-wasi` by `include/htscodecs_config.h:99-103` — the same three names
  are plain `calloc`/`free`.  There is no allocator override hook: no
  `hts_set_thread_allocation_fns`, no `hts_malloc`, no hook to install.
* **The shared library's ABI is 2, not the release version.**  The
  `2.0.12` triple in `libhtscodecs.so.2.0.12` reproduces libtool's
  `-version-info 3:12:1` from `configure.ac:63-65`, whose ABI number is
  `current - age` = 2.  The release version 1.6.7 is what `htscodecs.pc`
  reports and what `build.zig.zon` carries; the two are different quantities
  and neither is derived from the other.
* **One declared name has no implementation, and it is the only one.**  By
  construction the eleven installed upstream headers declare 46 functions;
  the target-derived subset this configuration exposes is 42 on `x86_64`, 35
  on `aarch64`, 31 on `riscv64` and `wasm32`, and in every one of those sets
  all but the name below have a definition this build compiles.  That name is
  `rans_compress_O0_32x16_sse4`: declared at `rANS_static32x16pr.h:83`-`:86`,
  its only definition textually present inside the `#if 0` block at
  `rANS_static32x16pr_sse4.c:113`-`:460`.  Every other name in the set is
  *required*: a provider that does not export one of them is refused at
  load rather than half used.  Which target exposes which kernel is a
  configuration question, not a guarantee — see the gate citations under
  [Native-build deviations](#native-build-deviations).

  What the single exception means depends on how you consume the library:
  * **Runtime-loaded** (`-Druntime=true`): it is the one optional entry in
    the dispatch table (`runtime/graph.zig`, `provider_optional`).  A provider
    that does not export it still loads, and every other codec works; the
    table field simply stays null.  A *call* to it stops the process naming
    the symbol — `htscodecs: the loaded provider does not export
    rans_compress_O0_32x16_sse4, which rans_compress_O0_32x16_sse4 needs; this
    provider is not the library this build describes`.  No scalar kernel
    stands in, no retry is attempted, and the codecs that do exist are not
    refused because one optional field is empty.
  * **Linked** (the default): there is no table, so the call is a direct
    reference to a name no object in the archive defines.  A program that
    calls it fails to link unless it supplies a real external definition of
    that exact name itself — a definition the caller owns, with the caller's
    own signature, and not something this package fabricates.  The same is
    true of a shared provider: an `x86_64` shared object built here does not
    export it, and the generated Windows export definition names only what
    each ISA kernel really defines — for SSE4, `rans_uncompress_O0_32x16_sse4`
    and `rans_uncompress_O1_32x16_sse4` (`build.zig:147`-`:150`).  That list
    is read out of what each kernel source *defines*, not out of the header's
    declaration list, so it cannot name a symbol the object does not contain.

  The library's own kernel selection never needs the missing encoder, and
  that is upstream's code rather than this fork stepping around it: the SSE4
  branch of the *encoder* dispatcher returns the scalar kernel
  (`rANS_static4x16pr.c:1001`-`:1004` for order 0, `:987`-`:990` for order 1),
  while the *decoder* dispatcher really does select the SSE4 decoders
  (`:1052`, `:1066`).  So on an SSE4-only machine the order-0 and order-1
  32x16 encoders run scalar code, exactly as upstream intends, and the
  missing function is never referenced by anything the library links.
* **A default build cannot read a bzip2 stream.**  The arithmetic coder's
  `ext` method (`arith_order_flag.ext`, byte `0x04`) delegates a block to
  bzip2, and it is compiled in only with `-Dbz2=true`.  Without it both
  directions fail for such a stream, and the facade reports
  `error.OperationFailed`.  Upstream's own `tests/dat/arith/u32.4` is one,
  which is why the tests accept either outcome for it.

### Nix

Canonical development is devenv — `devenv.nix`, `devenv.yaml` and `.envrc`,
with the nixpkgs input pinned.  The shell carries tools and tasks; the SDK
package is not realised on shell entry.

```
devenv shell                  # Zig 0.16.0, pkg-config, bzip2 + headers
devenv build outputs.static   # -Dlinkage=static   -> lib/libhtscodecs.a
devenv build outputs.shared   # -Dlinkage=dynamic  -> lib/libhtscodecs.so.2
nix build .#static
nix build .#shared
nix build                     # the default, which is static
```

`package.nix` is one uncurried function returning one derivation, with
`linkage` as its variant selector; `flake.nix` and `devenv.nix` are the two
entry points, and both pass `bzip2 = null` explicitly because `callPackage`
fills an argument from the package set whenever a matching attribute exists.
It imports no sibling, names no host path, downloads nothing, and copies no
licence or documentation file — `zig build install` installs those, so there
is exactly one copy of each.

Every task in `devenv.nix` changes into this SDK's own directory before it runs
anything, and that directory is read out of the module itself
(`builtins.toString ./.`), not taken from `$PWD` or `$DEVENV_ROOT`: a task body
runs with the *caller's* working directory, which under
`devenv --from path:<sdk>` is a scratch project holding `devenv.lock` and
`.devenv/` and none of `build.zig` or `consumer/`.

Each body then resolves the Zig caches itself, because `devenv tasks run` does
not run the shell hook: whatever you exported for `ZIG_LOCAL_CACHE_DIR` and
`ZIG_GLOBAL_CACHE_DIR` wins and is left alone, a missing one is filled from
`XDG_CACHE_HOME` and then from `TMPDIR`, and with neither of those set the task
says so and stops before it reaches the compiler.  Nothing falls back to `/tmp`,
`/var/tmp` or this checkout.  Every body then passes `-j8`, an explicit
`--cache-dir` and `--summary all`, so a run neither drops to one job nor leaves
`.zig-cache/` here and reports every step it took.  `--prefix` is passed on the
two routes that install — `sdk:build`, because a bare `zig build` *is* the
install step, and `consumer:run`, because `consumer/build.zig:135-138` hangs the
consumer's `run` step off its own install step — and on no other, because no
other step here depends on one.  Both prefixes live under your
`ZIG_LOCAL_CACHE_DIR`.

A static `libhtscodecs.a` still needs libc, libm and pthreads from the target
platform, so nothing here promises a wholly static executable.  The
derivation builds for the build platform only: `zig build` with no `-Dtarget`
compiles for the machine running it.

### System-library mode

`-fsys=htscodecs` links an installed `libhtscodecs` instead of compiling this
tree, and translates the *installed* headers, so the declarations and the
linked library always come from the same place.  In that mode `zig build test`
decodes upstream's own checked-in streams with the system library.  This
fork's `htscodecs_config.h` is not used there, so the per-ISA 32x16 entry
points stay hidden exactly when the installed library may not have been built
with them.

The same single exception holds in this mode, and for the same reason: the
installed headers are upstream's own pinned headers, so they declare
`rans_compress_O0_32x16_sse4` and upstream's own autotools build also never
compiles it.  Nothing in this mode either supplies a definition or pretends
the name is callable.

## Licence

The library is BSD-3-Clause, copyright Genome Research Limited, with three
exceptions that are public domain: `htscodecs/c_range_coder.h`
(Eugene Shelwien's dedication) and `htscodecs/rANS_byte.h` /
`htscodecs/rANS_word.h` (Fabien Giesen's `ryg_rans`, under a CC0 waiver whose
text lives only in `LICENSE.md:39-45`).  [`NOTICE.md`](NOTICE.md) carries the
per-file inventory with the notice each file actually has.

Files this fork wrote are BSD-3-Clause under an owner-authorized per-project
licence, recorded with the full text and the exhaustive path list in
[`FORK-LICENSE.md`](FORK-LICENSE.md).  Upstream authors are not credited with
fork work and no personal copyright identity is invented for it.
