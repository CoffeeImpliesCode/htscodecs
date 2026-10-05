# Fork notes

Issues met while designing the Zig build, the API surface and the tests.
Each entry records the evidence, the cause, what was done, and the rule
worth reusing.  Per-entry marks record what was known when the entry was
written; the fork's own gate results are stated separately below the legend,
and an entry marked **observed** quotes a gate receipt.  No entry claims a gate
that was not actually run.

Verification legend:

* **unverified** — the design is sound on the evidence cited, but no gate was
  run while writing this fork.  Nothing below should be read as a passing
  result.
* **observed** — a gate or command was actually run and the outcome is
  recorded.

The per-entry marks below record what was known when the entry was written.
The fork's own gate results, observed by the integrator with Zig 0.16.0, are:

* `zig build` 15/15 steps, `zig build test` 38/38 in Debug and in ReleaseSafe
  and with `-Dbz2=true`, `zig build smoke` 13/13, and
  `zig build check provenance` 67/67 over all six targets.  The consumer package
  passes and exercises every facade codec plus the raw C.  Receipts are listed
  in `CHANGELOG.md` entry 13 and in the workspace ledger.

* `HTSCODECS_PROVIDER=<provider> zig build test -Druntime=true
  -Dlinkage=static` 6/6: the runtime route against a static provider,
  exercising real compression in every mode the library has and decoding
  upstream's checked-in fixtures.  That is one host, one optimisation mode
  and one of the four runtime/linkage combinations; the shared-provider
  counterpart and the other two carry no receipt.  Recorded in
  `CHANGELOG.md` entry 16.

That is a statement about those commands and those steps.  It does not promote
any individual entry above its own mark, because an entry's claim and a step's
exit code are different things.

---

## 1. Every translation unit includes a header that autoconf generates

* **Evidence.** `grep -n 'config.h' htscodecs/*.c` matches nine files:
  `arith_dynamic.c:47`, `fqzcomp_qual.c:56`, `pack.c:34`,
  `rANS_static4x16pr.c:48`, `rANS_static32x16pr.c:34` and the four SIMD
  files.  `htscodecs/htscodecs.c:35` includes `version.h`, which upstream's
  `Makefile.am:113-124` generates with `git describe --dirty`.
* **Cause.** Confirmed, not a hypothesis: the sources have no
  `HAVE_CONFIG_H` guard, so the headers must exist at compile time.
* **Fix.** `build.zig` writes both into the cache.  `config.h` is a
  two-line shim that includes the checked-in `include/htscodecs_config.h`;
  `version.h` carries the pinned version.  The generated directory is on
  the include path of every C module.
* **Constraint.** The feature policy lives in a *checked-in* header, not in
  the generated one, so the C build and `b.addTranslateC` cannot disagree.
* **Rule.** When replacing a configure-based build, the generated headers
  are part of the contract; reproduce them, do not assume the sources are
  standalone.
* **Platforms.** All. **Version.** v1.6.7. **Verification.** unverified.

## 2. `git describe --dirty` would misreport this fork

* **Evidence.** `Makefile.am:115` runs
  `git describe --match 'v[0-9]\.[0-9]*' --dirty | sed 's/^v//'`.
* **Cause.** Confirmed.  `--dirty` marks the worktree as modified, which for
  this fork is always true, so `htscodecs_version()` would return something
  like `1.6.7-3-gc442bd7-dirty` describing this fork's additions as an
  upstream change.
* **Fix.** `build.zig` writes the pinned tag instead.  No git invocation at
  build time, so a source tarball without `.git` still builds.
* **Rule.** A pinned fork should derive its version from the pin, not from
  worktree state.
* **Verification.** unverified.

## 3. Without the cpuid declarations the SIMD kernels compile but are never called

* **Evidence.** `rANS_static4x16pr.c:807-812` guards the entire CPU
  detection block, and the `#include <cpuid.h>`, on
  `defined(__x86_64__) && HAVE_DECL___CPUID_COUNT && HAVE_DECL___GET_CPUID_MAX`.
  The `#else` at line 1148 is the comment's
  `!(defined(__GNUC__) && defined(__x86_64__)) && !defined(__ARM_NEON)`, and
  it hard-codes the scalar function pointers.
* **Cause.** Confirmed.  This is a silent downgrade, not an error: define
  `HAVE_SSE4_1` and the SSE4 object builds, but nothing ever calls it.
* **Fix.** `include/htscodecs_config.h` defines both `HAVE_DECL_*` on every
  x86-64 target, justified by `<cpuid.h>` being present in Zig's bundled
  compiler headers (`lib/include/cpuid.h` in the 0.16.0 distribution).
* **Rule.** When porting a library, treat "silently disabled" as the
  dangerous case and check the guard chain, not just the feature macro.
* **Platforms.** x86-64. **Verification.** unverified.

## 4. The x86 SIMD kernels self-guard; the Neon one does not

* **Evidence.** `rANS_static32x16pr_sse4.c:35`,
  `_avx2.c:36` and `_avx512.c:40` all open with
  `#if defined(__x86_64__) && defined(HAVE_...)`, so an empty translation
  unit is harmless off x86.  `rANS_static32x16pr_neon.c:36` includes
  `<arm_neon.h>` with no guard at all.
* **Cause.** Confirmed.  Compiling the Neon file for x86-64, riscv64 or
  wasm32 fails at the `#include`, not at a feature test.
* **Fix.** The build adds each kernel only when
  `target.result.cpu.arch` matches the kernel's recorded `arch`.
* **Rule.** Per-file ISA objects need an architecture predicate in the build
  graph, not only a preprocessor guard; one unguarded file breaks the whole
  cross matrix.
* **Verification.** unverified.

## 5. The Neon kernel is a separate translation unit, not an include

* **Evidence.** `rANS_static32x16pr.h:39-51` says the ARM code "is simply
  #included into the scalar file", but `rANS_static32x16pr.c` contains no
  `#include` of it, and `htscodecs/Makefile.am:50` lists
  `rANS_static32x16pr_neon.c` among the compiled sources.
* **Cause.** Stale upstream comment.  The code and the build file agree with
  each other and disagree with the comment.
* **Fix.** Built as its own object, as `Makefile.am` does.
* **Rule.** When a header comment and the build file disagree, check the
  source itself; the comment is the least reliable of the three.
* **Verification.** unverified.

## 6. `b.addTranslateC` cannot be given a configuration macro

* **Evidence.** In Zig 0.16.0, `std.Build.Step.TranslateC.Options` has
  exactly `root_source_file`, `target`, `optimize` and `link_libc`.  The
  include-path methods exist, but there is no way to add a `-D`.
* **Cause.** Confirmed, an API limitation rather than a bug.
* **Consequence.** `rANS_static32x16pr.h` hides the per-ISA 32x16
  declarations behind `HAVE_SSE4_1` / `HAVE_AVX2` / `HAVE_AVX512`.  Without
  a macro the translated interface would silently omit entry points the
  archive really exports, and with one applied only to the C build the two
  would describe different libraries.
* **Fix.** The aggregate header includes `htscodecs_config.h` before it,
  and that header is written in plain `#if defined(__x86_64__)` terms, so
  clang evaluates it against the target during translation exactly as it
  does during compilation.
* **Rule.** Keep build configuration in a header the translation unit can
  read; build-script-only macros cannot reach `translate-c`.
* **Verification.** unverified.

## 7. `fqzcomp_qual.h` uses `static const int` file-scope constants

* **Evidence.** `fqzcomp_qual.h:67-80` declares `GFLAG_MULTI_PARAM`,
  `GFLAG_HAVE_STAB`, `GFLAG_DO_REV` and the `PFLAG_*` family as
  `static const int`.  The header uses `static` nowhere else.
* **Cause.** Hypothesis: `translate-c` may reject or mangle
  internal-linkage file-scope variables.  Not confirmed, because confirming
  it needs a translation run, which is a gate.
* **Fix.** `include/htscodecs_all.h` and `include/htscodecs_system.h` define
  and undefine `static` around that single include, so the constants are
  ordinary file-scope constants for both C consumers and `translate-c`.  The
  values are identical either way, and the `#undef` restores the keyword
  immediately.
* **Rule.** An aggregate header for `translate-c` should not depend on
  unverifiable tool behaviour for a construct it does not control.
* **Verification.** unverified.  `test/facade_contract_test.zig` asserts
  `GFLAG_MULTI_PARAM` and `PFLAG_HAVE_QMAP` are present in the translated
  module, so a failure here is a named test failure rather than a mystery.

## 8. The two codecs use the same bit values for different things

* **Evidence.** `rANS_static4x16.h:75-103` defines `RANS_ORDER_PACK 0x80`,
  `RLE 0x40`, `CAT 0x20`, `NOSZ 0x10`, `STRIPE 0x08`, `X32 0x04`.
  `arith_dynamic.c:38-46` defines `X_PACK 0x80`, `X_RLE 0x40`,
  `X_CAT 0x20`, `X_NOSZ 0x10`, `X_STRIPE 0x08`, `X_EXT 0x04`.
* **Cause.** Confirmed: the two formats deliberately share bit positions,
  and 0x04 means "32-way unroll" for one and "hand it to bzip2" for the
  other.  A single shared `OrderFlags` table would be wrong.
* **Fix.** Two tables, `htscodecs.order_flag` and
  `htscodecs.arith_order_flag`, and the round-trip test skips the `x32` row
  for the arithmetic coder.
* **Rule.** Identical encodings of different concepts are the most
  dangerous kind of shared constant; name them per format.
* **Verification.** unverified.

## 9. bzip2 support cannot be on by default

* **Evidence.** `configure.ac:93-110` makes `--disable-bz2` legal and
  errors out if libbz2 is missing.  Without `HAVE_LIBBZ2`,
  `arith_dynamic.c:968-971` prints
  `Htscodecs has been compiled without libbz2 support` and returns NULL, and
  `:1231` fails the decode.  `tests/dat/arith/u32.4` has order byte 0x04,
  so it is a bzip2 stream.
* **Cause.** Confirmed.
* **Fix.** `-Dbz2=true` opts in and links `-lbz2`.  The default build
  reports the affected method as `error.OperationFailed` and says so in
  `README.zig.md`.
* **Rule.** An optional upstream dependency must keep its exact failure
  semantics and say which artifacts become undecodable, rather than being
  stubbed out to look successful.
* **Verification.** unverified.
  `test/fixture_decode_test.zig` has a test for `u32.4` that accepts either
  outcome and checks the bytes in the success branch, so the test is
  meaningful in both builds.

## 10. `wasi-libc` declares pthreads it does not implement

* **Evidence.** `utils.c:43-44` and `:104` use `pthread_once`,
  `pthread_key_create`, `pthread_getspecific` and `pthread_setspecific`,
  guarded by `#ifndef NO_THREADS`.  `rANS_static4x16pr.c:857` and `:951`
  use `pthread_once` for CPU detection, with `#ifdef NO_THREADS` fallbacks
  already written at `:948` and `:1022`.
* **Cause.** Hypothesis, from the wasi-libc surface: the entry points are
  declared for ABI completeness but are not implemented for a target with
  no threads.  Not confirmed without a link attempt.
* **Fix.** `NO_THREADS` is defined for `__wasi__`, selecting upstream's own
  calloc/free fallback.  Semantics are unchanged, only the scratch-pool
  strategy.
* **Rule.** Prefer an existing upstream fallback over inventing a new path
  when a target lacks a platform facility.
* **Platforms.** wasm32-wasi. **Verification.** unverified.

## 11. Never pre-judge a cross target from the meaning of its name

* **Evidence.** An earlier draft of `build.zig` marked `aarch64-macos-none`
  as unbuildable, on the reasoning that the `none` ABI carries no libc and
  htscodecs is a libc C library (`pack.c`, `rle.c`, `fqzcomp_qual.c`,
  `arith_dynamic.c` and `tokenise_name3.c` all include `<stdlib.h>`,
  `<stdio.h>`, `<string.h>` and `<math.h>`).  That reasoning was false.
  Zig 0.16's `lib/std/Target.zig` `Abi.default` maps `.macos` to `.none`
  (around lines 930 and 945), so `aarch64-macos` and `aarch64-macos-none`
  are the same, ordinary, normal macOS ABI.  The word "none" in a target
  triple does not mean what its name suggests.
* **Cause.** Confirmed.  The claim was made by reading the target *name* and
  a general impression of what a libc-less ABI means, without reading
  `Abi.default` in the pinned toolchain.  A build script that hard-codes a
  verdict about a target is a build script that can be wrong about a target
  it never tested.
* **Fix.** The `blocked` mechanism is gone.  The matrix now has no
  pre-judgement field, `check` builds all six requested targets, and
  `-Dcheck-targets=` narrows the run or names an opt-in extra; an
  unrecognised name is an error rather than a silent no-op.  Whether this
  machine can satisfy a target's prerequisites is left to the gate to
  report, because that is an observation, not an assumption.
* **Rule.** A build script may encode *policy* about a target; it may not
  encode a *verdict* it has not obtained from a run.  "I think this cannot
  build" and "this did not build" are different claims and only one of them
  belongs in source.
* **Platforms.** Any. **Verification.** the correction itself is a source
  review of the pinned toolchain; no gate has been run, so whether
  `aarch64-macos-none` builds here remains unobserved.

## 12. Upstream's `NULL` does not say why

* **Evidence.** `rans_uncompress_to_4x16` at
  `rANS_static4x16pr.c:1705-1706` does `if (*out_size < osz) goto err;`
  without writing the required size, and `arith_uncompress_to` at
  `arith_dynamic.c` behaves the same.  The `out == NULL` path *does* set
  `*out_size`, but that is the allocating form.
* **Cause.** Confirmed: invalid stream, undersized buffer and failed
  allocation all collapse into one return value.
* **Fix.** Superseded and re-cut by entry 22.  Every post-call NULL is now
  `error.OperationFailed`, which names no cause; `error.Malformed` is gone.
  `error.BufferTooSmall` survives only where the facade compared two
  caller-supplied lengths and knows the destination is short, and a new
  `error.InvalidArgument` covers arguments the facade rejects itself.  A
  zero-length destination is still refused before the call, because
  upstream refuses it too and the answer is unambiguous.  `*CompressBound`
  exists so a caller can remove the one cause it is able to act on.
* **Rule.** Do not invent precision a foreign API does not have.  A coarse
  error that is documented beats a fine-grained one that is guessed.
* **Verification.** unverified.

## 13. `rans_compress` does not validate its order

* **Evidence.** `rANS_static.c` ends with
  `return order ? rans_compress_O1(...) : rans_compress_O0(...);`.
* **Cause.** Confirmed: no range check exists.
* **Fix.** The doc comment says so, and
  `test/roundtrip_test.zig` asserts that order 2 produces byte-identical
  output to order 1.  The 32x16 wrappers do check, because those two
  functions have a genuine O0/O1/O2/O3 selection that an out-of-range value
  would miss.
* **Rule.** Test the surprising behaviour rather than the intended one when
  the intended one was never implemented.
* **Verification.** unverified.

## 14. `hts_pack` dirties its output before it can fail

* **Evidence.** `pack.c` writes `out_meta[1..n]` and `out_meta[0] = n` and
  only then checks `if (n > 16) return NULL;`.
* **Cause.** Confirmed.  A failed pack leaves a plausible-looking map behind.
* **Fix.** `pack.packData` documents that `meta` is meaningless when it
  returns `error.OperationFailed`, and the round-trip test asserts the failure on
  a 256-symbol alphabet.
* **Rule.** When wrapping a function that can fail after writing outputs,
  say what the outputs are worth on the failure path.
* **Verification.** unverified.

## 15. The 32x16 streams do not carry their length

* **Evidence.** `rans_uncompress_O0_32x16` at
  `rANS_static32x16pr.c:254-276` takes `out_sz` as a plain value and, when
  `out` is NULL, `malloc`s exactly that much.  There is no size field to
  read, unlike `rans_uncompress_to_4x16` and `arith_uncompress_to`.
* **Cause.** Confirmed, a format property.
* **Fix.** `rans32x16.uncompressTo` takes the destination the caller sized
  and returns `out.len`; the round-trip test decodes into a buffer of the
  original size and checks the content.
* **Rule.** A buffer API whose format omits the length has to make the
  caller supply it, and the wrapper should say so at the signature.
* **Verification.** unverified.

## 16. System-library mode must not translate this fork's headers

* **Evidence.** The bundled headers describe v1.6.7.  An installed
  `libhtscodecs` on a distribution may be older, so translating
  `include/htscodecs_all.h` and linking `-lhtscodecs` would publish
  declarations for symbols the linked library may not export.
* **Cause.** Design constraint, recorded before any mismatch was observed.
  No version mismatch has actually been seen in this fork.
* **Fix.** `-fsys=htscodecs` switches the translation root to
  `include/htscodecs_system.h`, which includes the *installed* headers off
  the system include path.  Fork-only `htscodecs_config.h` is not included
  there, so the per-ISA 32x16 declarations stay hidden exactly when the
  installed build might not have them, and a missing declaration is a build
  error naming it rather than a link error later.  That same private header
  now also discharges the assumption the installed public headers leave
  open: an earlier positive system-library wave failed across its cells with
  fixed-width integer types and `size_t` undeclared in the translated
  surface, because `pack.h`, `rle.h`, `tokenise_name3.h` and the rest carry no
  `#include` line of their own and this file reached them without
  establishing what they use.  It now includes the `<stdint.h>` and
  `<stddef.h>` family ahead of the installed `<htscodecs/...>` set.  The
  native aggregate header `include/htscodecs_all.h` is untouched by that
  change — it already carried the same include set at `:93-94` — and the
  change set also carries the selected-platform-configuration fix and the
  removal of the empty shim.
* **Rule.** Headers and library must come from the same source in any
  system-integration mode.  Whichever header is the translation root owes
  the standard types the public headers it reaches use, because those
  headers include nothing themselves.
* **Verification.** **Applied; not yet re-gated**, and still `unverified` as
  a behavioural claim: no receipt re-runs htscodecs after the fix, so nothing
  is promoted on its account and no earlier failing cell is recorded as a
  pass.  The 53-target cohort `20261004T221720228710Z-45046` (receipt
  `htscodecs-53-target-8.json`; 18 runtime passes, 31 `build_only`, runtime
  failures `aarch64_be-linux` and `thumbeb-linux`, build failures
  `aarch64-netbsd` and `aarch64_be-netbsd`, driver exit 1) and the 2026-10-05
  compile-only baselines `20261005T014547Z-797a73f2` both predate it, and the
  positive-system wave itself is not an all-PASS record.  Settling it needs a
  fresh run of this SDK's own gates after the fix.

## 17. The provenance gate has to run without a working git

* **Evidence.** The task is to verify a pinned upstream commit, but the
  gate must also work from an unpacked source tree.
* **Cause.** Design constraint.
* **Fix.** As described, but not in the first cut: see entries 25 and 26 for
  what actually shipped and why.  The file-presence half is a configure-time
  check against the package build root using the Zig 0.16 `Io.Dir` API, and
  it is the only half wired into an ordinary `zig build`.  The commit half is
  the separate `provenance-history` step, which fails where the history is
  absent and the caller asked for it.
* **Rule.** A provenance gate should distinguish "the record is missing"
  from "the tool to check the record is missing".
* **Verification.** unverified.

## 18. Reflection proves a declaration resolves, never that its body compiles

* **Evidence.** An earlier draft used `test/coverage_test.zig` containing
  nothing but `std.testing.refAllDeclsRecursive(htscodecs)`, and
  `src/htscodecs.zig` carried a `test { std.testing.refAllDecls(@This()); }`
  block.  `check` was then described as proving that "every public facade
  method" was analysed.
* **Cause.** Two distinct errors.  First, reflection resolves a
  declaration's *type*; instantiating a function body needs a *call*, so a
  reflection-only gate can report success while a body fails to type-check.
  Second, and independently, both blocks are tautologies: they have no
  assertions and therefore cannot fail, so even the type-resolution signal
  they do give is thrown away.
* **Fix.** Both blocks are gone.  `check` compiles the four behavioural test
  files for each target, and those tests are the deliberate callers: every
  public method is invoked with a real assertion about its result, and
  compiling that test for a target is what instantiates the body.  The
  build script and `README.zig.md` now say exactly that instead of claiming
  reflection did the work.
* **Related cleanup, same policy.** Removed from the new tests, because
  they can only restate something recorded elsewhere: a version-string
  assertion (`version() == 100607`), a default-constant assertion
  (`max_stream_len == maxInt(c_int)`), a `@hasDecl` sweep over the
  translated names, bare non-throwing calls, and every "produced more than
  zero bytes" length check.  What replaced the `ransSetCpu` bare call is a
  real test: the mask replaces itself outright, so 0 means "no 32x16
  kernel" and 0xFFFF is what restores automatic selection, and the round
  trip must reproduce the input in both.  The version pin now lives only in
  `zig build provenance` and the smoke report, which is where a pin belongs.
* **Rule.** Ask what a test could *catch*, not what it *mentions*.  A test
  that cannot fail is documentation wearing a test's clothes, and a gate
  built on one is decoration.
* **Platforms.** Any. **Verification.** unverified; this is a source-level
  audit against the stated policy, not a gate result.

## 19. Build outputs must be ignored and kept out of the package hash

* **Status.** Packaging requirement, applied proactively.  This is *not* an
  observed defect: no `.zig-cache`, `zig-cache` or `zig-out` directory exists
  anywhere in this worktree, and no gate has been run here.  Nothing below
  is a report of a contamination that happened.
* **Why it matters for this fork.** Two separate consumers of the tree would
  otherwise be affected.  A normal `zig build` creates `.zig-cache/` and
  `zig-out/`, and without an ignore rule those show up as untracked files in
  the next commit, which is how a build directory ends up in a downstream
  repository.  Separately, the package hash is computed from the manifest's
  `paths`, so a cache directory that got into `paths` would change the hash
  on every build and defeat the dependency cache entirely.
* **Fix.** Two mechanisms, deliberately independent.
  1. `.gitignore` gains an appended block for `.zig-cache/` and `zig-out/`,
     the two directories `zig build` creates by default in Zig 0.16.  The
     patterns carry no leading slash, so they also cover `consumer/`, which
     is a package in its own right.  The block is appended after upstream's
     47 entries; none of them was reordered or removed, because they still
     describe the autotools build that is left in the tree.
  2. Both manifests use an explicit allowlist rather than `.paths = .{""}`.
     `build.zig.zon` lists nineteen paths, none of which is a build output
     directory, and `consumer/build.zig.zon` lists three.  A cache
     directory therefore cannot enter a package hash even if it exists, and
     an operator redirecting the cache elsewhere, as the parent does with
     `--cache-dir`, changes nothing about the hash.
* **Rule.** An allowlist beats a denylist for package paths: it fails closed
  when a new build output appears, where an ignore rule fails open.  Do both,
  and treat them as one requirement.
* **Platforms.** Any. **Verification.** unverified; verified statically that
  neither manifest path list can match a build output directory.

## 20. Two encoders write their inputs, and the signature has to say so

* **Evidence.**
  * `tokenise_name3.c:1500` does `blk[i] = '\0';` for every separator as it
    encodes.  Upstream's `char *blk` is non-const for exactly this reason.
  * `fqzcomp_qual.c:790` and `:795` clamp `s->len[]` so the records sum to
    the input length; `:589` and `:596` OR the codec's chosen selector
    into `s->flags[]`; `:763` sets `GFLAG_DO_REV` for `vers == 3` and
    `:1087-1109` reverses flagged records before encoding; `:1193-1217`
    reverses them back on success. An early failure can leave them changed.
* **Cause.** The facade took `[]const u8` for the block and quality bytes
  and `[]const u32` for the slice arrays, and erased constness with a
  `@constCast` behind a comment asserting that "no encoder or decoder in
  the library writes through an input pointer".  That blanket claim was
  false, and because it justified the erasure everywhere, it would have
  re-licensed the same defect on the next edit.
* **Fix.** The signatures now carry the truth: `tok3.encodeNames` takes
  `[]u8`, `fqzcomp.compress` takes `in: []u8`, and `Slice.len`/`Slice.flags`
  are `[]u32`.  The `cPtr` comment was rewritten to name the two exceptions
  and say that every other call through it is genuinely read-only, so the
  next reader has the specific fact rather than a sweeping one.
* **Tests.** `test/roundtrip_test.zig` asserts the observable consequences
  directly: the tokeniser leaves no `\n` in the block it consumed, the
  fqzcomp 4.0 stream leaves the quality bytes alone, a declared length that
  overshoots the block comes back clamped, and a successful 3.1 stream leaves
  quality bytes unchanged while round-tripping flagged records.
* **Rule.** A const-erasing cast needs a per-caller justification, not a
  library-wide one.  When the justification is a comment, it is worth
  grepping the upstream sources for writes before believing it — which is
  exactly what was not done here.
* **Platforms.** Any. **Verification.** unverified; the upstream line
  references were read directly, no gate run.

## 21. The pack metadata map needs 257 bytes, and `nsym == 1` needs a guard

* **Evidence.** `pack.c:67-70` walks the input assigning each used symbol
  the next code and writing `out_meta[n] = i` *before* the width check at
  `:72`.  With all 256 byte values present the last write lands on index
  256.  A 256-byte map puts that on the next field.  Separately,
  `pack.c:213-215` handles `nsym == 1` with `memcpy(out, data, len)` and no
  comparison against `out_len` at all, and `unpackMeta` legitimately
  returns 1 for an alphabet wider than 16 symbols.
* **Cause.** Upstream's own callers use 256-byte maps, so the one-byte
  overflow is inherited rather than introduced.  The facade compounded it
  by handing a `[256]u8` field straight through, and by documenting
  `unpackTo` as needing an exact-size destination without enforcing it.
* **Fix.** `pack.Meta.map` is `[257]u8`, so the final write lands in the
  spare byte.  `pack.unpackTo` refuses `nsym == 1` when `data.len` exceeds
  `out.len` before calling upstream.  Both maps are now passed as slices
  with a checked `min_map_len` of 256, which removes the 256-versus-257
  choice from every call site rather than hiding it in one.
* **Tests.** `test/roundtrip_test.zig` pins both: a full 256-symbol
  alphabet must fail *and* leave a sentinel `meta_len` untouched while the
  overflow lands in `map[256]`; and `unpackTo` with `nsym == 1` must refuse
  a short destination while still accepting the exact one.
* **Rule.** When a foreign API writes a length-derived structure before it
  validates the length, the wrapper owns the bound.  A documented
  precondition that nothing checks is a comment, not a contract.
* **Platforms.** Any. **Verification.** unverified; upstream lines read
  directly, no gate run.

## 22. A NULL from upstream is not a diagnosis

* **Evidence.** `rans_compress_to_4x16` returns NULL both when the
  destination is too small and when an allocation fails;
  `arith_dynamic.c:968-971` returns NULL for a compiled-out method;
  the decoders return NULL for a rejected stream, a wrong-sized
  destination and a failed allocation.  None of the sites writes a reason
  anywhere.
* **Cause.** The facade mapped an encoding NULL to `error.BufferTooSmall`,
  which is a claim the C API does not support.  A caller told to retry with
  a bigger buffer would loop forever against an allocation failure or a
  build without bzip2, and the facade's own documentation on `arith`
  contradicted its own behaviour by naming a different error for the same
  NULL.
* **First fix, still wrong.** Every post-call NULL became
  `error.Malformed`.  That fixed the contradiction but kept the defect: the
  C API cannot tell a caller that the stream is malformed, because the same
  NULL also covers insufficient capacity, a compiled-out method and a
  failed allocation.  Putting a footnote under a diagnosis is still a
  diagnosis.
* **Fix.** `error.Malformed` is gone.  `error.OperationFailed` carries every
  post-call NULL and names no cause, because none is recoverable.  The set
  is now cut along a single line — whether *the facade* knows the cause:
  `LengthOverflow` and `InvalidArgument` for arguments it inspects before
  the call, `BufferTooSmall` only where it compared two caller-supplied
  lengths and knows the destination is short (a zero-length destination,
  and `pack.unpackTo`'s `nsym == 1` copy), and `OperationFailed` for
  everything upstream decided.  The `Error` docs spell out every cause a
  NULL can carry, and the encode docs point at `*CompressBound` as the only
  lever the caller has.
* **Rule.** An error name is a claim about the source.  If the source
  collapses four failures into one value, no member of the set may
  distinguish them; a footnote does not make a name honest.  Draw the
  boundary at what your own code checked, not at what you suspect.
* **Platforms.** Any. **Verification.** unverified; no gate run.

## 23. The manifest fingerprint belonged to no package this fork has

* **Evidence.** Observed. The native-build gate exited 1 in 0.17 s with
  `build.zig.zon:1:2: error: invalid fingerprint: 0x902207d5e89af9ef; if this
  is a new or forked package, use this value: 0x1cae8edb6408e4ce`
  (`local://foundation-htscodecs-native-build.json`). The manifest's comment
  said the value came from `zig init --minimal`, which stamps the
  fingerprint of whatever placeholder name it created, not of `.htscodecs`.
* **Cause.** Confirmed by the message: the value was not this package's.
  The manifest is read before anything else, so this was the first thing
  any gate in this fork had a chance to say — every other result below is
  still unobserved.
* **Fix.** `.fingerprint` is the value the toolchain named, and the comment
  now records that provenance so the next reader does not restore an `init`
  placeholder from memory.
* **Rule.** A fingerprint is package identity, not boilerplate. Take the
  toolchain's own value and write down where it came from.
* **Platforms.** Any. **Verification.** observed for the rejection only.
  Whether the build then succeeds is not observed; no gate has been re-run
  in this tree.

## 24. `packed` is a keyword, and the parser names only the first one

* **Evidence.** Observed. The formatter gate reported four parse errors,
  `test/roundtrip_test.zig:167:11`, `test/facade_contract_test.zig:117:15`,
  `examples/codec_demo.zig:72:15` and `consumer/src/main.zig:55:72`, each
  "expected 'an identifier', found 'packed'". Source-confirmed: `packed` is
  `keyword_packed` in the pinned toolchain's own table,
  `lib/std/zig/tokenizer.zig:43`. The receipt also under-reports: those four
  files held eleven further occurrences the diagnostic never named
  (roundtrip 201, 230, 257, 283, 328; codec_demo 101; consumer 97, 154, 194,
  210, 235), and `README.zig.md:102` carried it in a documented example.
* **Cause.** Confirmed. The name came across from upstream C, where
  `packed` is an ordinary variable (`rANS_static4x16pr.c:1218`,
  `arith_dynamic.c:734`) — a name worth reading once and then re-deciding
  for the target language, not one to copy.
* **Fix.** Every occurrence is `encoded`, the name this fork already uses
  for the same thing in `fixtures.zig:58`. Nothing else changed: the string
  literals that print the words "packed version" — the smoke banner at
  `examples/codec_demo.zig:31` and the grep in
  `.github/workflows/verify.yml:62` — are untouched, so CI still matches
  what the demo prints, and no public declaration changed name.
* **Rule.** Check ported names against the target language's reserved
  words, and treat a parse error as one error, not as the list. When a
  diagnostic can only report the first occurrence, fix by class.
* **Platforms.** Any. **Verification.** the keyword status is
  source-confirmed against the pinned toolchain and the renamed set was
  enumerated from the sources; the formatter has not been re-run here.

## 25. `std.fs.cwd()` is gone, and the process CWD was the wrong root anyway

* **Evidence.** Source-confirmed against the pinned toolchain. Zig 0.16.0's
  `std.fs` declares no `cwd` at all: only `std.Io.Dir.cwd`
  (`lib/std/Io/Dir.zig:88`), `std.Build.Cache.Directory.cwd` and
  `std.Build.Cache.Path.cwd` have one. Every `Io.Dir` method takes the `Io`
  as a parameter — `lib/std/Io/Dir.zig:438` is
  `pub fn access(dir: Dir, io: Io, sub_path: []const u8, options: AccessOptions)`,
  and its error set (`AccessError`, `:411`) carries `FileNotFound`. The call
  was `std.fs.cwd().access(path, .{})`, so it no longer resolves; and even
  if it had, it tested the *process* working directory, which for a package
  consumed through `b.dependency()` is not this tree. The toolchain's own
  build steps show the spelling:
  `const io = b.graph.io;` then `b.build_root.handle.<method>(io, ...)`
  (`lib/std/Build/Step/UpdateSourceFiles.zig:75` and `:81`), and
  `Build.build_root` is a `Cache.Directory` whose `handle` is an `Io.Dir` and
  whose `path` is "needed when passing the directory to a child process"
  (`lib/std/Build/Cache/Directory.zig:10-14`).
* **Cause.** Confirmed. Code written against the pre-0.16 filesystem API, and
  using the one root a build script must never depend on.
* **Fix.** `b.build_root.handle.access(b.graph.io, path, .{})`, with
  `error.FileNotFound` named apart from every other `AccessError`, so an
  unreadable file is reported as unreadable and not as absent. The git step
  takes the same root: `git -C <b.build_root.path orelse ".">`.
* **Rule.** A build script resolves paths against the package build root,
  never the process CWD, and takes its `Io` from the graph the way the
  toolchain's own steps do.
* **Platforms.** Any. **Verification.** source-confirmed by reading the
  pinned std; no build has been run here.

## 26. Git history is not a property of the sources

* **Evidence.** `addProvenanceGate` had both halves in one step, and
  `b.getInstallStep()` depended on it, so every `zig build` ran
  `git cat-file -e <sha>^{commit}`. A source package fetched without
  `.git` — a release tarball, a vendored copy, a distribution's source tree
  — could not build at all, although every byte it needs is present.
* **Cause.** Confirmed by reading the function. Entry 17 describes this
  split as though it had been implemented; the code had not implemented it,
  and that note was the only thing claiming otherwise. A gate that needs a
  tool has become a gate the build needs.
* **Fix.** `provenance` is the source-integrity half alone and stays in the
  install step. `provenance-history` is a separate step holding the
  `git cat-file` check, which CI runs where a clone exists. Asked for
  without a history it fails; nothing skips it, and it reports no success it
  did not observe. `UPSTREAM.md` and `README.zig.md` now describe the two
  steps as two.
* **Rule.** Separate what can be checked from where it is checked. A gate
  that requires a tool must not become a gate the build requires.
* **Platforms.** Any. **Verification.** source-confirmed; the split is
  visible in `build.zig` and in the two CI steps, but nothing has been run.

## 27. The pristine-source gate contradicted the fork's own divergence

* **Evidence.** `.github/workflows/verify.yml` diffed the pinned commit
  against a path list that included `.gitignore`, while `CHANGELOG.md` entry
  8 documents an appended block in exactly that file. The gate and the
  record contradicted each other, and one of them had to go.
* **Cause.** Confirmed. The list was taken to be the set of files
  `UPSTREAM.md` claims are untouched, but `UPSTREAM.md` never claimed
  `.gitignore` was untouched — only the CI list did.
* **Fix.** `.gitignore` leaves the pristine list and is named in
  `UPSTREAM.md` and `NOTICE.md` as this fork's single deliberate exception.
  It gets no replacement diff. A step that asserts the appended block is
  literally `.zig-cache/` and `zig-out/`, with its comments stripped, fails
  on a reworded comment and passes while a real upstream file is missing:
  it compares this fork's bookkeeping with itself. Every upstream C source,
  header, test, script and licence file stays in the list.
* **Rule.** When a gate contradicts a documented divergence, narrow the gate
  to the paths the claim is about and record the exception in prose. A
  replacement that looks stronger is not a stronger test.
* **Platforms.** Any. **Verification.** source-confirmed against the files;
  the CI step has not run here.

## 28. Grepping the smoke report tests the wording, not the library

* **Evidence.** The native job ran `zig build smoke`, then ran it a second
  time through `tee` and grepped for `^htscodecs 1.6.7 (packed version
  100607)$`, `match$` and `released with free()`. The version string is a
  recorded constant this fork already declined to assert (entry 18), and the
  rest is prose this fork wrote.
* **Cause.** Confirmed. The step was a duplicate run plus three assertions
  about the report's own wording, and it could not fail for a reason a caller
  would care about.
* **Fix.** The step is gone. `zig build smoke` runs once and its exit code is
  the check: the example already decodes every upstream fixture and compares
  it against the uncompressed input, returning `error.OracleMismatch` on any
  difference (`examples/codec_demo.zig:126` and its four siblings), so a
  disagreement with upstream is a non-zero exit and not a printed warning.
  The report is still printed for a human reader; it is no longer a contract.
* **Rule.** A gate has to assert something that can be wrong. Re-grepping
  your own output asserts the string you chose to print.
* **Platforms.** Any. **Verification.** source-confirmed; the workflow has
  not run here.

## 29. A generated directory was returned as if it were a file

* **Evidence.** The parent reported five `++` sites in `build.zig`, an
  undeclared `required_files`, `std.Target` having no `Arch` member, and
  `Step.WriteFile` having no `path` field. Reading the pinned
  `lib/std/Build/Step/WriteFile.zig` showed `addWriteFiles` returns
  `*Step.WriteFile`, whose directory accessor is `getDirectory()`, and that
  `add(sub_path, bytes)` returns the *file* it just wrote. `addGeneratedHeaders`
  returned the result of `files.add("htscodecs_config", "htscodecs_config")` —
  a placeholder file — while both real headers were written under
  `htscodecs_config/`, so the include path handed to every C source pointed at
  a file where a directory was needed, and the write step would have tried to
  create a directory over that same placeholder.
* **Cause.** Confirmed. A `LazyPath` from `add` and a `LazyPath` for the step's
  directory are different things, and a helper that returns "the path" has to
  say which. The `++` sites are the same mistake in a different costume: the
  operator needs a comptime-known result length, so it cannot join a value
  that only exists at build time.
* **Fix.** The helper returns `files.getDirectory()` and adds no placeholder.
  The runtime joins became `b.fmt`, and the two target-name lists the
  `-Dcheck-targets` help and its failure message share are joined from the
  tables the check walks with `std.mem.join`. The literal-only joins stay.
  The gate iterates `required_records`, and the kernels' architecture field is
  `std.Target.Cpu.Arch`.
* **Rule.** Read the accessor off the type you are holding, not off the shape
  you remember: `getDirectory()` and `getPath()` are different questions, and
  a generated step's file and its directory are different paths. In Zig,
  `++` on a runtime value is a type error, not a slow path.
* **Platforms.** Zig 0.16.0. **Verification.** source-confirmed against the
  pinned `lib/std`; the build script has not been compiled here.

## 30. The installed-header proof restated prototypes it could get wrong

* **Evidence.** `addInstalledHeaderProof` wrote two C translation units that
  each `#include <htscodecs/htscodecs_all.h>` and then re-declared twenty
  upstream functions before taking their addresses. Three of the
  declarations disagreed with the headers the package installs: `hts_pack`
  takes five arguments and an `int *out_meta_len`, `arith_compress` puts
  `order` before `out_size`, and `tok3_encode_names` takes `int *out_len`.
  It also named `htscodecs_proof_version`, which nothing defines, and read
  `hts_rle_encode` as taking three arguments.
* **Cause.** Confirmed. A redeclaration that disagrees with the header it is
  meant to prove is a compile error, and it proves nothing extra: the header
  has already declared every name, so the compile step is still the test. The
  invented name was worse than useless — at `-O0` the address comparison
  leaves a relocation for a symbol the archive does not have.
* **Fix.** The units include the installed aggregate and take the address of
  the names it declares, with no redeclaration. `htscodecs_version` replaces
  the invented name: `htscodecs.h` declares it and `htscodecs.c` defines it,
  so the link proves the archive exports it. `var_get_u32` and `fast_log` are
  taken with upstream's own return types, `int` and `double`. The include
  path is `b.getInstallPath(.header, "")` — the header *directory*, which is
  what makes `<htscodecs/htscodecs_all.h>` resolve — and `LazyPath` has no
  `custom` variant to carry it.
* **Rule.** A proof that includes a header should consume the header, not
  paraphrase it. Every restated signature is a second thing that can be wrong
  and a third failure mode that has nothing to do with the claim.
* **Platforms.** Any C toolchain. **Verification.** source-confirmed against
  `pack.h`, `rle.h`, `arith_dynamic.h` and `tokenise_name3.h`; the `headers`
  step has not run here.

*(Amended by entries 35 and 36.  Consuming the header is still the right rule,
but "the header has already declared every name" does not finish the argument:
a declaration is not a definition.  One declared name here,
`rans_compress_O0_32x16_sse4`, has no definition in this archive, so taking
its address leaves an undefined symbol rather than proving anything.  The
consequence is recorded in `CHANGELOG.md` entry 16 and in `README.md`'s
matrix; nothing has been linked here to observe it.)*

*(The consequence above has since been withdrawn; the rule has not.  The proof
no longer takes that address.  Its first translation unit now names
`rans_uncompress_O0_32x16_sse4` — defined at
`rANS_static32x16pr_sse4.c:462`, already in this build's own SSE4 export list
at `build.zig:208`-`:211` — with that decoder's real signature, whose fourth
parameter is `unsigned int` by value where the encoder's is `unsigned int *`
(`build.zig:208`-`:211`, with the reasoning in that function's doc comment
at `:147`-`:157`).  So the three-way claim this entry made is now two-way:
the export list and the dispatch still have to be read out of the objects,
and the proof no longer supplies a third failure of its own.  The header is
still the right thing to consume; it is still not a definition list.
Source-confirmed only — `zig build headers` and `headers-run` have not been run
since, so the row is unverified and not green.)*

## 31. A documented guard that was an assert, and a bound the wrapper did not own

* **Evidence.** The module documentation promised that aliasing is rejected
  "in every build mode" and `Error.InvalidArgument` listed overlapping input
  and output, but `checkDisjoint` was a `std.debug.assert`, which
  `std.debug.assert` documents as unreachable in ReleaseFast and ReleaseSmall.
  `Error.BufferTooSmall` in the same file promised a refusal for an
  `rle.encode` whose `run` or `out` was too small, and `rle.encode` checked
  neither: `hts_rle_encode` writes one literal per input byte into `out`
  (`rle.c:122`) and one `var_put_u32` per run into `run` with a NULL end
  pointer (`rle.c:131`).
* **Cause.** Confirmed. The assert was the right instinct in the wrong place:
  it expresses "this must not happen" rather than "this is the answer", and
  the public contract is an answer. The `rle` bound was simply not owned —
  upstream's allocating path asks for `2 * data_len`, which is generous, and
  that generosity was copied into the caller-facing doc as if it were the
  requirement.
* **Fix.** `checkDisjoint` returns `error.InvalidArgument` from an ordinary
  comparison, in every build mode, and all eleven call sites propagate it.
  `rle.encode` requires `data.len` bytes in each of `run` and `out` and says
  why: a run of length L costs at most L varint bytes, so `data.len` is the
  true bound for both. A regression test covers each refusal.
* **Rule.** Guard a public contract with an ordinary comparison and give it
  the name the documentation already promises; a `std.debug.assert` is a
  redundant net, not a guard. When a wrapper documents a bound, check it —
  upstream trusting its caller is not a reason for the facade to.
* **Platforms.** Any. **Verification.** source-confirmed against `rle.c` and
  the pinned `lib/std`; the tests have not run here.

## 32. The fork's README was upstream's file, and the build it described was not this build

* **Evidence.** `README.md` was byte-identical to upstream's, sha256
  `b77d87e58c92f1aae4e74f8071c589ae23d424da82d2d73fa8434525be22de26`, and
  its build section said "If building from git, you'll need to recreate the
  configure script using autoconf" followed by `./configure; make`.  The
  repository has no `configure` step: `build.zig` builds the library, and
  entry 1 has said so since the beginning.  The same file also carried a
  Cirrus badge for the upstream maintainer's CI, which entry 6 removed from
  `.cirrus.yml` and left in the prose.
* **Cause.** Confirmed, and it is not a licence question.  Preserving an
  upstream file unmodified is right for provenance and wrong for
  orientation: the reader who opens the repository is looking for how to
  build *this*, and the file that answers that question was answering it for
  a different build.  Preserving the bytes and serving them from the
  canonical path were being treated as one decision when they are two.
* **Fix.** Split them.  Upstream's bytes were copied to `README.upstream.md`
  first and the digest verified equal before `README.md` was replaced, so the
  preserved copy is a fact rather than a hope.  `README.md` is new prose in a
  fixed order — native-source deviations, native-build deviations with a
  dated history link, the build/run/test matrix, consumption — and links to
  `README.upstream.md` in its first paragraph.  Two other owners had to
  follow the bytes: the CI pinned-commit diff now names `README.upstream.md`,
  and `build.zig.zon` `.paths` had to carry every new path so a fetched
  package is not quietly missing its own licence record.
* **Rule.** Preserve upstream bytes at a path that names them, and let the
  canonical path describe the build that actually exists.  Every gate that
  compares against the pinned commit follows the bytes, not the name: a
  pristine-diff list is a list of paths, and moving a file's contents without
  moving that list turns a provenance check into a tautology.  Verify the
  copy by digest before overwriting anything.
* **Platforms.** Any fork that vendors an upstream documentation file.
  **Verification.** source-confirmed: `cmp` and `sha256sum` reported the two
  paths identical immediately before `README.md` was rewritten, and the
  driver's proof record carries the same digest.  No build has been run since.

## 33. A per-project licence is a grant with a path list, not a label on a tree

* **Evidence.** Upstream's grant is a default with three named exceptions:
  `LICENSE.md:1-2` covers everything, `LICENSE.md:31-37` takes
  `c_range_coder.h`, `rANS_byte.h` and `rANS_word.h` out of it as public
  domain, and `LICENSE.md:39-45` carries Fabien Giesen's CC0 waiver.  Reading
  the two rANS headers shows where that waiver is *not*: each has a one-line
  public-domain statement at line 11 and no waiver text at all.
  `c_range_coder.h:1-4` is a different mechanism again — a dedication in the
  file, credited for modification, with no CC0 anywhere.  Meanwhile the files
  this fork wrote had no grant of any kind, only the implied one.
* **Cause.** Confirmed.  Upstream's terms say nothing about fork-authored
  files, so "the tree is BSD" was simultaneously incomplete (it claimed
  nothing for the fork's own work) and wrong (it would have swept three
  public-domain headers into a BSD label).  Both errors come from treating a
  licence as a property of a directory instead of of a file.
* **Fix.** `FORK-LICENSE.md` records the owner authorization, the grant
  (BSD-3-Clause, matching upstream's primary terms), the SPDX identifier,
  the exact path list it covers and the paths it does not, including
  `.gitignore`'s mixed status.  No individual is named as the fork's
  copyright holder, and upstream authors are not credited with fork work.
  `NOTICE.md` §3 became a per-file inventory with the notice each file
  actually carries and its line numbers, and the CC0 text's single home in
  `LICENSE.md` is stated where it is easy to get wrong.
* **Rule.** Name the term and the line, per file.  A metadata label describes
  the library; it never overrides a file-specific term.  Ship the licence
  text the exceptions cite — `zig build install` puts `LICENSE.md` in
  `share/licenses/htscodecs/` for that reason — and give each copy one owner.
* **Platforms.** Any fork with per-file licence exceptions.
  **Verification.** source-confirmed by reading `LICENSE.md`,
  `c_range_coder.h`, `rANS_byte.h`, `rANS_word.h`, `utils.h` and every source
  and test file's header notice.  No redistribution has been exercised.

## 34. Two packaging variants are one build script and one flag

* **Evidence.** The Zig setup hook in nixpkgs appends `--prefix $prefix` and
  `--release=safe` to `zig build install` on its own, and
  `LibraryOptions.linkage` defaults to `.static`, so a derivation that says
  nothing says less than it appears to.  A shared variant of this library
  needs more than a flag: the per-ISA 32x16 objects are separate compilations
  and have to be PIC too, and on Windows the DLL's export table would be empty
  because no htscodecs header carries `dllexport` decoration.
* **Cause.** The defaults were inherited, not declared, and the variants were
  expressed in the wrong place: a `{static,shared,default}` set inside
  `package.nix` makes the packaging file a second convention that a second
  entry point has to know the shape of.
* **Fix.** One uncurried `package.nix` returning one derivation, with
  `linkage ? "static"` as the selector; `flake.nix` and `devenv.nix` choose it
  and pass `bzip2 = null`, because `callPackage` fills an argument from the
  package set whenever a matching attribute exists.  The setup-hook phases are
  disabled (`dontUseZigConfigure`, `dontUseZigBuild`, `dontUseZigCheck`,
  `dontUseZigInstall`) but `dontInstall` is *not* set, because it would
  disable the derivation's own `installPhase`.  That phase names every flag:
  `-j"$NIX_BUILD_CORES"`, `--prefix`, one `-Doptimize`, `-Dcpu=baseline`,
  `-Dlinkage`, and `-Dbz2=true` only with a `bzip2` argument.  Both Zig caches
  go under `$TMPDIR`, since the source tree is read-only.  PIC for the ISA
  objects and the Windows export list belong to the build graph; the
  derivation names neither.
* **Rule.** A derivation states its own flags instead of inheriting a setup
  hook's, and one build script serves every packaging variant with an option
  rather than a copy.  The canonical development shell holds tools, not the
  package it develops: entering a shell must not build the library.  And a
  build that installs licence material has exactly one owner, so a
  derivation does not copy what `zig build install` already installed.
* **Platforms.** Zig 0.16.0 with nixpkgs `c7def046b9a883d46974757852106483d741586f`.
  **Verification.** source-confirmed against the pinned `lib/std`, the
  nixpkgs `zig/generic.nix` and `setup-hook.sh` read out of the local nixpkgs
  tree.  No derivation has been evaluated and no flake has been built; the
  driver owns `flake.lock` and `devenv.lock` and runs those gates.

## 35. A declaration in a header is not an implementation in the library

* **Evidence.**  `rANS_static32x16pr.h:83`-`:86` declares
  `rans_compress_O0_32x16_sse4` under
  `HAVE_SSE4_1 && HAVE_SSSE3 && HAVE_POPCNT`, and the same header's section
  comment at `:81` already says "Intel SSE4 implementation.  Only the O0
  decoder for now".  The only definition upstream ever wrote is inside the
  `#if 0` block at `rANS_static32x16pr_sse4.c:113`-`:460`, under its own reason
  at `:111`-`:112`: "SSE4 implementation of the Order-0 encoder is poorly
  performing.  Disabled for now."  The file compiles; the function does not
  exist in the object.  Reading the eleven installed upstream headers gives 46
  function declarations, of which this is the single one with no compiled
  definition; the target-derived subset a configuration exposes is 42 on
  `x86_64`, 35 on `aarch64`, 31 on `riscv64` and `wasm32`.
* **Cause.**  Upstream's header and its source disagree, deliberately and at a
  release tag, and the disagreement is invisible to every tool that reads
  headers.  Anything that derives a symbol list from a header inherits it:
  a Windows export definition then names a symbol the object does not
  contain, a runtime dispatch table demands one no provider can ever supply,
  and a proof translation unit that takes the address of each declared name
  cannot link.  All three land at link or load time on one architecture only,
  so nothing narrower than a full link sees them.  (The third of those three
  has since been repaired: the installed-header proof now names a decoder the
  SSE4 kernel defines rather than the encoder that upstream left in `#if 0`.
  The first two are why the export lists and the optional-name entry exist at
  all, and they are unchanged.)
* **Fix.**  The `#if 0` stays exactly as pinned — re-enabling it would edit
  native source, and writing a replacement would publish a function upstream
  never wrote under upstream's name.  Instead the exception is named in one
  place in each record, the per-kernel export lists in `build.zig` are read
  out of what each kernel source defines, and the runtime route marks that
  single name optional.  A call to it is refused by name rather than served:
  a panic in a runtime-loaded build, and an ordinary link error in a linked
  one, where the caller must supply its own external definition.
* **Rule.**  "Declared in the installed header" is a claim about
  declarations, and it has to be stated as one.  An absent implementation is
  recorded by name, with its source evidence and its target-derived scope —
  never as a general caution about "optional symbols", and never by
  publishing a stand-in that covers part of what the missing function would
  have done.  Where one declaration is the exception, the rest of the surface
  is stated as required rather than left to an assumption that a declaration
  implies a definition.
* **Platforms.**  Any pinned C library whose installed headers and sources can
  disagree.  **Verification.**  source-confirmed by reading the pinned header
  and the pinned kernel source, and by reading the export lists and the
  dispatch's optional-name table in this tree.  No build, link or load has
  been run here.

## 36. The required-symbol set is target-derived, and a symbol list is read out of the objects

* **Evidence.**  Which 32x16 entry points a configuration even declares is
  fixed by preprocessor gates: `rANS_static32x16pr.h:82` for the SSE4 trio,
  `:101` for AVX2, `:125` for AVX512, `:149` for Neon, and
  `include/htscodecs_config.h:74`-`:90` derives the three x86 sets from
  `__x86_64__` alone.  So "every function the header set declares" is not one
  number: it is 42 on `x86_64`, 35 on `aarch64`, 31 on `riscv64` and
  `wasm32`.  Two places in this tree had drifted from that, and both have
  since been corrected.  `build.zig` justified keeping the kernel export
  lists off the header's declarations by citing
  `rans_compress_O1_32x16_sse4` at `rANS_static32x16pr.h:93`; line 93
  declares `rans_uncompress_O1_32x16_sse4`, and no order-1 SSE4 encoder is
  declared anywhere in the header — the list was right and the stated reason
  was not, and `build.zig:121`-`:132` now gives the real one.  And the
  installed-header proof's first translation unit took the address of
  `rans_compress_O0_32x16_sse4` under the header's own macros, which was the
  undefined symbol of entry 35; it now names `rans_uncompress_O0_32x16_sse4`
  (`build.zig:1396`-`:1407`), so that half of the evidence no longer holds and
  `README.md`'s header-proof row has been corrected rather than left to imply
  an expected link failure.
* **Cause.**  A symbol list written by reading a header is a claim about a
  header.  It stays right until the configuration changes underneath it, and
  when it is wrong the error appears at link time, on one architecture, in a
  step nobody runs routinely.  Marking too little optional is just as wrong as
  marking too much: an optional symbol whose absence is ordinary teaches a
  provider contract that is not the one the rest of the file is enforcing.
* **Fix.**  The dispatch asks for exactly what this build's own translation
  produced, so its required set cannot be a second hand-maintained
  convention; per-kernel export lists are what each kernel source defines; and
  precisely one name — the entry-35 exception, with its source citation in
  the code — is optional.  Everything else the configured headers declare is
  required, and a provider that does not export one of them is refused when
  it loads rather than half used.  The two drifted statements are recorded in
  `CHANGELOG.md` entry 16 rather than quietly rewritten, because the files
  that carry them belong to another owner.
* **Rule.**  Derive symbol lists from the artifacts, not from the headers that
  describe them, and let the compiler's own output define the set.  Scope a
  claim like "every declaration is implemented" to the configuration it was
  counted in.  And when one exception exists, write down the rest as
  required: a required set that nobody stated is indistinguishable from an
  optional one nobody checked.
* **Platforms.**  Any build that publishes a dispatch table, an export
  definition or a proof translation unit.  **Verification.**
  source-confirmed by reading the gates, the export tables and the dispatch's
  name lists in this tree.  Nothing has been linked or loaded here.  The link
  consequence this entry recorded for the header proof has been withdrawn —
  the proof no longer references the undefined name — and its replacement has
  not been linked either, so `README.md`'s header row is unverified and not
  green.  Both corrections above are comment- and name-level edits that
  change no artifact, and both landed after the 2026-10-04 receipts recorded
  in entry 37.

## 37. A platform that cannot load a shared object refuses the request, it does not answer it

* **Evidence.**  Observed, from the parent's run and not reproduced here:
  `zig build check-shared` over this package's six targets exited 1 with
  61/67 steps.  The five hosted rows compiled completely; the `wasm32-wasi`
  row failed at the library with `wasm-ld: warning: creating shared
  libraries, with -shared, is not yet stable`, and each of that row's five
  consumers then failed on its own with `error: unrecognized file extension
  of parameter '.../htscodecs.wasm'` — four `test-obj` compilations and the
  `build-exe` for `examples/codec_demo.zig`.  Receipt
  `htscodecs-current-six-target-check-shared-2026-10-04T14-44-05.968751+00-00.json`
  in the current-baseline evidence directory, 2026-10-04T14:44:05Z, exit 1,
  187 s.  The platform fact behind it is `SOURCE-CONFIRMED` in Zig 0.16.0's
  own source: `std.Target.DynamicLinker.kind` is `.none` for `.wasi`
  (`lib/std/Target.zig:2385`) and the function is
  `lib/std/Target.zig:2345`-`:2403`.
* **Cause.**  A linker will happily emit a shared object for a target that
  has no loader for it.  The request was honest — "give me the shared
  library" — and the toolchain answered it with a file named
  `htscodecs.wasm`, which is not a shared library, and the build graph then
  spent the rest of the row failing to link five consumers against a
  parameter whose extension the linker does not recognise.  Every one of
  those five errors was downstream of one unexamined platform fact, and none
  of them named it.
* **Fix.**  `targetCarriesSharedObject` resolves the platform question from
  `std.Target.DynamicLinker.kind`, with `.windows` returned separately as the
  one `.none` that still carries a shared object (`:2380`: a PE/COFF image has
  no interpreter path, and its imports are resolved by the loader inside the
  OS).  `sharedObjectRefusal` renders one message from it.  `build()` calls
  it for the selected published target before any step is created, so
  `zig build -Dtarget=wasm32-wasi -Dlinkage=dynamic` stops at configure;
  `addOneCheckTarget` turns an unsupported matrix row into an `addFail` step
  carrying the same text, so `check-shared` reports the row by name, builds
  nothing for it and still compiles the other five.  Nothing is substituted,
  no row is dropped, and the static matrix — a separate step — still walks
  that target.
* **Rule.**  When a build option names an artifact and the platform cannot
  produce that artifact, the build produces it or says why it cannot.  A
  build that emits something else under the requested name has answered a
  question nobody asked, and it does so most expensively: the real cost is
  not the wrong file, it is every consumer that fails afterwards on a
  symptom of the substitution rather than on its cause.  Refuse at the point
  the option is read, put the platform fact and the spelling that works in
  the message, and never let the refusal take down a *different* step that
  happens to walk the same target — the two linkages are two steps here for
  exactly that reason.
* **Targets bound.**  Any target whose OS answers `.none` from
  `std.Target.DynamicLinker.kind`, other than `.windows`.  In this matrix
  that is `wasm32-wasi`.  The predicate reads the OS tag, so a target with a
  dynamic linker for some ABIs and not others is not distinguished; if such
  a combination is ever added to the matrix, the predicate is where it has
  to be refined.  The default `-Dlinkage=static` and the orthogonal
  `-Druntime=true` are untouched, and so is `-fsys=htscodecs`, where the
  installed library's linkage is not this build's to choose.
* **Verification.**  Observed, twice over, by the driver and not re-run here.
  First the failure above: `zig build check-shared` over the six targets
  exited 1 with 61/67 steps.  Then, after the change, seven runs on
  2026-10-04 (`local://foundation-htscodecs-refusal-verification-manifest.json`,
  listed in `CHANGELOG.md` entry 17):
  * `zig build check` — exit 0, 66/66, all six targets including
    `wasm32-wasi`.  The static delivery for the refused target is intact.
  * `zig build check-shared -Dcheck-targets=<the five hosted rows>` — exit 0,
    59/59; the same five with `-Druntime=true` — exit 0, 41/41.  The hosted
    shared graphs are real, in both facade routes.
  * `zig build check-shared` over all six — exit 1, 58/60, **one** failed
    step, and it is the refusal: `error: htscodecs: check-shared row
    wasm32-wasi: …`.  The five hosted rows compiled, no `htscodecs.wasm` was
    produced, and `unrecognized file extension` appears nowhere in the
    output.  Five downstream link errors became one named refusal.
  * `zig build install -Dtarget=wasm32-wasi -Dlinkage=dynamic` — exit 1 at
    configure, inside `build()` in `build.zig`, before any step exists.
  * `zig build test smoke` — exit 0 with 42 tests passed under
    `-Dlinkage=static` and again under `-Dlinkage=dynamic`.

  Two exits of 1 are the requested outcomes; neither asserts that a shared
  `wasm32-wasi` artifact builds, because there is none.  Still
  `PENDING-VERIFICATION`, and deliberately not claimed by these receipts:
  the three source corrections that landed *after* them (the header-proof
  symbol, the private fixtures module, the split `devenv` tasks), the other
  optimisation modes, `-Dbz2=true`, `-fsys=htscodecs`, the Nix and devenv
  packaging surfaces, and the 53-platform matrix.

## 38. An aggregate header is not a header the bundled preprocessor can be trusted to read

* **Evidence.**  `include/htscodecs_all.h` is not self-contained.  It reaches
  five libc headers: `<stdint.h>` and `<stddef.h>` at `:93`-`:94`, and through
  `utils.h:37-39` — included at `include/htscodecs_all.h:113` — `<string.h>`,
  `<stdlib.h>` and `<math.h>`.  The only other include the aggregate names is
  `varint.h:52`'s `"varint2.h"`, and this build never reaches it: that line is
  inside the `#ifdef VARINT2` branch at `varint.h:51-53`, nothing in this
  package defines `VARINT2`, and both the C core and Aro read the `#else` at
  `:53`.  `zig translate-c` parses C with **Aro**, which preprocesses as well
  as parses, so every one of those five has to be read by Aro before the parser
  sees an htscodecs declaration.
  Observed, from the parent's 53-platform run and not re-run here: fifteen of
  the fifty-three published cells failed to translate this aggregate with Aro
  alone — nine NetBSD, five OpenBSD and `x86-windows` — and each failure was
  in Aro's own read of that target's C library.  The other thirty-eight
  translated from the aggregate as it stands.
  The same fact bounds what the installed prefix offers.  `htscodecs/varint2.h`
  is in the tree and in neither install table — upstream's own
  `nobase_include_HEADERS` omits it (`Makefile.am:37-46`), `upstream_headers`
  (`build.zig:349-361`) carries `varint.h` and not `varint2.h`, `fork_headers`
  (`:363-366`) carries the two fork headers, and `installHeaders`
  (`build.zig:1672-1687`) installs exactly those two — while the installed
  `htscodecs/varint.h` keeps its `#ifdef VARINT2` branch verbatim.  A consumer
  that compiles with `-DVARINT2` against the installed prefix therefore has no
  `varint2.h` to find, and the `headers` step cannot stand in for one: it
  compiles the installed aggregate under this package's own configuration
  (`build.zig:1702-1704`), where that branch is off.  `PENDING-VERIFICATION`,
  and deliberately not claimed here: no `-DVARINT2` consumer build has been
  run against an installed prefix, so the failure above is read off the source
  and not observed.
* **Cause.**  Three C libraries and three different facts, none of them in
  htscodecs:
  * **NetBSD.**  `__END_DECLS` is `__END_PUBLIC_DECLS`
    (`generic-netbsd/sys/cdefs.h:431-432`), and under the `#if
    __GNUC_PREREQ__(4, 0)` at `:408` that macro is framed in two `_Pragma`
    operators — `__BEGIN_PUBLIC_DECLS` at `:411-412`, `__END_PUBLIC_DECLS` at
    `:413` — over `extern "C" {` and `}` (`:399-400`).  Aro is given
    `__GNUC__` when it emulates Clang or GCC
    (`lib/compiler/aro/aro/Compilation.zig:269-274`), so that branch is the
    one it reads.  The `#else` at `:417-424` is the plain-token spelling every
    other family uses.
  * **OpenBSD ILP32** — `arm-openbsd`, `powerpc-openbsd`, `x86-openbsd`.  Aro
    ships its own `<stddef.h>` and reads it ahead of the target's, and that
    file typedefs `size_t` as `__SIZE_TYPE__`
    (`lib/compiler/aro/include/stddef.h:8`), while
    `generic-openbsd/sys/types.h:171-174` typedefs the same name as `__size_t`
    under a `_SIZE_T_DEFINED_` guard that Aro's header never sets.  At 32 bits
    the two spellings are `unsigned int` and `unsigned long`; at 64 bits both
    are `unsigned long` and the definitions agree, which is exactly why the
    three ILP32 cells fail and the five 64-bit ones do not.
  * **OpenBSD MIPS** — `mips64-openbsd`, `mips64el-openbsd`.
    `generic-openbsd/mips64/endian.h:32-41` `#error`s unless `__MIPSEL__` or
    `__MIPSEB__` is defined, and Aro's MIPS table gives all four MIPS
    architectures `__mips__` and `_mips` and nothing else
    (`lib/compiler/aro/aro/Compilation.zig:635-642`).
  * **`x86-windows`.**  `any-windows-any/stdlib.h:717` includes `<malloc.h>`,
    and `any-windows-any/malloc.h:183-187` derives `_ALLOCA_S_MARKER_SIZE`
    from `_ARM_`, `_X86_`, `__ia64__`, `__x86_64` or `__aarch64__`;
    `_MarkAllocaS` (`:191-197`), `_malloca` (`:206-211`) and `_FreeAllocaS`
    (`:219-224`) then name it, and Aro emits `static __inline` bodies — its
    own glibc translation of this aggregate carries 83 of them.  Aro's table
    is readable and separates the cells: it gives `.x86_64` `__x86_64`
    (`Compilation.zig:436-440`) and the two AArch64 members `__aarch64__`
    (`:691-692`), which is why `x86_64-windows` and `aarch64-windows` are not
    in the failing list, and it defines `_X86_` nowhere and `_ARM_` never for
    the 32-bit Arm members (`:684-690`), which is why `x86-windows` is.
* **Fix.**  `TranslationRoute`, `translationRoute` and `preprocessedAggregate`
  in `build.zig` (`:1076-1323`), read once per target from
  `addPublicModule`'s `.root_source_file` (`:1364-1370`).  `.aro` reads
  `include/htscodecs_all.h` as it stands.  `.preprocessed` runs `zig cc -E
  -dD -x c` over the same file first — the compiler running the build script,
  the same `-target` when the target is not native, the same `c_flags`, the
  same `-DHTSCODECS_WITH_BZ2=1` the translation already carried, and a
  `-MD`/`-MF` depfile through `addPrefixedDepFileOutputArg` — and Aro parses
  what it wrote.  Nothing is stubbed, narrowed or renamed, no `-I` is needed
  because the aggregate resolves its own includes, and no macro of the
  compiler's own is predefined: the front end in front is the compiler that
  compiles the C core.  `-fsys=htscodecs` is excluded by construction and
  keeps Aro.
* **Rule.**  An aggregate header's portability is bounded by the front end
  reading it, and a bundled front end is not evidence about a foreign libc.
  When the two disagree, put the target's own preprocessor in front of the
  parser and hand the parser its output — do not define the macro the missing
  predefine would have supplied, because that macro is a statement about what
  the target is.  State the condition as the property the cause turns on (an
  OS tag, a pointer width, an arch member), never as the list of triples that
  happened to fail, so the next architecture of the family is covered instead
  of silently left behind.  And keep the macro set on the preprocessing line
  identical to the compile line's, or the archive and the translated
  interface describe two different builds.
* **Targets bound.**  Any Zig 0.16 target on NetBSD; on OpenBSD with a pointer
  width other than 64 or an architecture of `.mips64`/`.mips64el`; and on
  32-bit x86 Windows.  Everything else in this matrix keeps Aro.  The Windows
  clause is `.x86` rather than "32-bit Windows" on purpose: `.x86` is the cell
  that was observed failing, and 32-bit Arm Windows is not a cell this package
  builds at all, so widening it there would be a change with no observation
  behind it.  The Aro table says such a cell would fail the same way, and the
  clause is where that is corrected if one ever reaches this aggregate.
* **Verification.**  `PENDING-VERIFICATION`.  The fifteen failures above are
  the parent's observations of the tree *before* these edits, and nothing has
  been run since.  Note first what cannot be run: `zig build check` reaches
  none of the fifteen.  `-Dcheck-targets` accepts only the six names in
  `matrix` and the three in `extra_matrix`
  (`build.zig:410-457`), every one of them already on the `.aro` route, and
  widening either table would change the published six-target baseline that
  §6 of `AGENTS.md` fixes — so that is a contract question, not a debugging
  move, and it is not taken here.  `zig build test -Dtarget=<cell>` does
  build the translation, but it also *runs* the test binaries and needs the
  foreign runner.  So the gates are:
  * `zig build check -j8 --summary all` over the default six targets — proves
    the `.aro` route is untouched for every cell that was already green, and
    in particular that `x86_64-windows-gnu` and `aarch64-macos-none` still
    translate with no extra front end.
  * `cross-test` from the package root, `zig-build` profile — the full
    53-platform matrix, and the only gate that reaches all fifteen.  Its
    per-target logs name the extra front end `preprocess htscodecs_all.h
    <triple>`, so a cell that took Aro and a cell that took the new front end
    are distinguishable in the summary rather than merely both green.

## 39. An architecture family with two members is one test, not two

* **Evidence.**  Zig 0.16 gives big-endian AArch64 its own
  `std.Target.Cpu.Arch` member: `aarch64` at `lib/std/Target.zig:1327` and
  `aarch64_be` at `:1328`, the same way it splits `.thumb`/`.thumbeb`
  (`:1374`-`:1375`) and `.mips64`/`.mips64el` (`:1352`-`:1353`), and it folds
  such a pair back into one member only where endianness makes no difference
  to what is generated (`:1444`, `:3671`).  The kernel gate read
  `target.result.cpu.arch != kernel.arch` with `kernel.arch == .aarch64`, so
  on `.aarch64_be` it omitted the object.  Clang defines `__ARM_NEON` and
  `__aarch64__` for both members, and Aro's table agrees
  (`lib/compiler/aro/aro/Compilation.zig:691-692`, `:734-736`), so on the
  big-endian cell both halves still compiled: the kernel body at
  `rANS_static32x16pr_neon.c:35` and the scalar dispatcher's Neon half at
  `rANS_static4x16pr.c:1072`, which returns `rans_compress_O0_32x16_neon`,
  `rans_compress_O1_32x16_neon`, `rans_uncompress_O0_32x16_neon` and
  `rans_uncompress_O1_32x16_neon` at `:1112-1113` and `:1135-1136`.  Observed
  in the parent's 53-platform run on the `aarch64_be-linux` cell: the
  dispatcher referenced all four and the archive did not have them.
* **Cause.**  An enum that means "this ISA" where the graph meant "this ISA
  family".  `__aarch64__` is defined by both members and says nothing about
  endianness, so a guard written against it has two targets in front of it and
  a one-member test answers only one.  The failure is a link error naming four
  undefined symbols, and it appears on the *big-endian* cell only, which is
  the cell nobody runs by hand.
* **Fix.**  `SimdKernel.arch` becomes `SimdKernel.archs: []const
  std.Target.Cpu.Arch` (`build.zig:194-200`), the Neon entry lists
  `.aarch64` and `.aarch64_be` (`:237-240`), and one predicate
  `targetBuildsKernel` (`:261-266`) is the only thing that reads it.  The
  three x86 kernels keep the single member `.x86_64`, which is the whole
  family.  Both existing callers use it — `addCoreLibrary` (`:854`) and
  `addWin32ModuleDefinition` (`:914`) — so an export table and an object
  closure still cannot disagree about which kernels exist.  The kernel's own
  `<arm_neon.h>` (`rANS_static32x16pr_neon.c:36`) is a compiler builtin header
  at `lib/include/arm_neon.h`, not a per-endianness one, so it resolves for
  the new member exactly as for the old one.
* **Rule.**  When a source guard is the specification of *which targets* a
  translation unit belongs to, the build graph's selection must be the same
  specification, member for member.  Write the family, not the enum value
  that happens to be first, and say which preprocessor macros the family
  turns on — `__aarch64__` here, `__x86_64__` for the three x86 kernels.  And
  keep one predicate behind every caller, so adding a member cannot fix the
  archive while leaving the Windows export list behind.
* **Targets bound.**  Any target whose `std.Target.Cpu.Arch` is `.aarch64_be`;
  in this matrix, `aarch64_be-linux` and `aarch64_be-netbsd`.  `.armeb` and
  `.thumbeb` are deliberately *not* members: neither defines `__aarch64__`, so
  the kernel takes its own `#else`
  (`rANS_static32x16pr_neon.c:1973-1975`) and the dispatcher takes the scalar
  `#else` (`rANS_static4x16pr.c:1148`), which hard-codes the scalar 32x16
  pointers and calls nothing.  No kernel is added or removed for any other
  target, and no target loses an object.
* **Verification.**  `PENDING-VERIFICATION`.  The `aarch64_be-linux`
  observation above is the parent's, of the tree before this edit.  The runs
  that would move this:
  * `zig build -Dtarget=aarch64_be-linux-gnu -j8 --summary all` — the cell
    that failed, and the only cell this change newly compiles an object for.
    `build` is the right step, not `test`: the archive, the translation and
    `bin/htscodecs-demo` are all installed, and the demo's link is where the
    four undefined names used to be reported.  `test` would additionally
    *run* foreign binaries and needs the runner `cross-test` supplies.
  * `zig build check` over the default six-target matrix — proves the
    `.aarch64` and `.x86_64` cells are unaffected and that the default
    `aarch64-linux-gnu` row still builds the same archive.
  * `zig build check-shared -Dcheck-targets=x86_64-windows-gnu` — exercises
    the second caller of the predicate, the generated `.def`, on the one
    target whose export table it feeds.

## 40. Big-endian 32-bit Arm is a native boundary, not a hole in the build graph

* **Evidence.**  Observed in the parent's 53-platform run, on the
  `thumbeb-linux` cell and not re-run here: the cell builds and links, and
  what it reports is a mismatch in the codec's own output.  It is not one of
  the fifteen translation failures of entry 38 and not the link failure of
  entry 39.  Source-wise it is expected to build: `thumbeb` does not define
  `__aarch64__`, so `rANS_static4x16pr.c:1072`'s `#elif` is not taken, its
  scalar `#else` at `:1148` hard-codes the scalar 32x16 pointers, and the
  Neon kernel is not part of that cell's closure — which is why
  `SimdKernel.archs` lists no `.thumbeb`.
* **Cause.**  Not established, and deliberately not guessed here.  What the
  source shows is a boundary rather than a build defect: the output format is
  byte-defined, `htscodecs/htscodecs_endian.h:78-88` claims big-endian
  support for `__THUMBEB__` among others, and upstream's autotools build has
  never been exercised on this target by anything in this repository.
* **Fix.**  None, here.  No `.c` and no `.h` upstream file is touched: the
  correction would be in upstream's big-endian 32-bit Arm codec path, it
  needs its own reproduced failure and its own causal patch, and its own
  integrity records.  No test is removed, skipped, relaxed or made
  target-conditional, and no cell is dropped from any matrix.  The cell keeps
  its name and reports what it is.
* **Rule.**  A build graph's job ends where the algorithm begins.  When a
  target compiles, links and then disagrees with the reference bytes, the
  answer is a recorded platform boundary with the failing assertion named —
  never a green cell produced by narrowing the test, and never a C edit made
  to make a target's own output match itself.
* **Targets bound.**  `thumbeb-linux` in this matrix.  `armeb-linux` and
  `armeb-netbsd` share the same big-endian 32-bit Arm family and belong to
  the same boundary; they are build-only cells here and are not claimed either
  way.
* **Verification.**  `OBSERVED` for the mismatch itself — the parent's run,
  against this tree, which this change does not touch on that cell — and
  nothing else is claimed.  The `cross-test` row for `thumbeb-linux` remains
  a reported boundary after this change; it is not expected to turn green
  and must not be recorded as one.

## 41. A task body inherits the caller's directory, and a scratch project is not the source

* **Evidence.**  Observed on 2026-10-04 in the parent's Nix acceptance run for
  this SDK, and not re-run here.  Both devenv gates failed before reaching a
  build: `sdk:provenance` printed `error: no build.zig file found, in the
  current directory or any parent directories`, and `consumer:run` printed
  `cd: consumer: No such file or directory`.  Both bodies were correct as
  written; what was missing is a statement of *where* they run.
* **Cause.**  devenv materialises a task as a generated program and runs it
  with the caller's working directory.  The canonical entry is
  `devenv --from path:<this SDK>`, which hands that program the project
  directory beside the tree — a directory the caller chose, holding
  `devenv.lock` and `.devenv/` and none of `build.zig`, `consumer/` or the
  provenance records.  `$DEVENV_ROOT` names that project, so trusting it is
  what a task that reads `$PWD` or `$DEVENV_ROOT` would do, and it is wrong
  for exactly this reason.  The second half of the same mistake is quieter: a
  body that ran in the right place but let `zig build` take its own defaults
  would write `.zig-cache/` and, on any install step, `zig-out/` into a working
  tree whose digests the driver compares before and after a run.
* **Fix.**  One binding, used as the first line of every body:
  `sdkRoot = builtins.toString ./.`, rendered through `lib.escapeShellArg` and
  entered as `cd <root> || exit 1`.  Both halves of that expression are
  load-bearing.  `./.` resolves against the file that writes it, so the root is
  this SDK whatever directory the caller stood in; and `builtins.toString`
  rather than an interpolated `${./.}` is what keeps the path this working
  tree, because the interpolated form asks Nix for a store copy of this whole
  tree — read-only, and not the tree `build.zig` and the digests describe.
  The caches are then resolved by the body itself rather than by
  `enterShell`, because `devenv tasks run --mode single` does not run the shell
  hook: whatever the caller exported for `ZIG_LOCAL_CACHE_DIR` and
  `ZIG_GLOBAL_CACHE_DIR` wins and is never overwritten, a missing one comes from
  `$XDG_CACHE_HOME` and then from `$TMPDIR`, and with neither set the body names
  what is missing and exits before it reaches the compiler — `/tmp`, `/var/tmp`,
  a store path and this checkout are all refused.  Every body then carries
  `-j8`, an explicit `--cache-dir` and `--summary all`, and `--prefix` on the
  two routes that install (`sdk:build` and `consumer:run`) and on no other.
* **Rule.**  A task that names a file must first name the directory that file
  is in.  The directory is a property of the module that declares the task,
  read from the module, never inherited from the caller and never reconstructed
  from a project variable — and a build tool's own relative defaults
  (`--cache-dir .zig-cache`, `--prefix zig-out`) are the same class of
  assumption, resolved the same way.
* **Verification.**  `PENDING-VERIFICATION`.  No task, script or gate in this
  SDK has been run since these edits.  The two failures above are the parent's
  observations of the tree before them, and a devenv entry for this SDK after
  the configuration freeze is what would replace them.

## 42. Packed bits cannot establish the caller's original unpacked size

* **Condition.** `pack.unpackTo` receives packed bytes, a symbol count, a
  map and a caller-sized destination, but no original unpacked-size field.
* **Symptom.** Its old doc promised `InvalidArgument` for a destination that
  was not the exact original size, although the wrapper inspected no such
  field. The review's further claim that `nsym == 0` returns NULL for a
  wrong size is refuted by `htscodecs/pack.c:335-337`: that branch fills the
  caller's requested length and returns the destination.
* **Fix.** State the exact-size caller obligation without inventing a
  validator. The native packed-input length checks for `nsym` 8, 4 and 2
  (`htscodecs/pack.c:235-236`, `:269-270`, `:311-312`) can return NULL, and
  that remains `OperationFailed`. Preserve the existing `nsym == 1`
  copy-capacity check and its `BufferTooSmall` result.
* **Targets bound.** Every target and optimization mode; linked and loaded
  dispatch share the same facade and native size semantics.
* **Verification.** `SOURCE-CONFIRMED` native branches. On 2026-10-04 the
  parent's corrected native linked Debug fixture observed `nsym == 8`
  with 128 packed bytes: exact capacity 1024 wrote 1024 matching bytes;
  capacity 4096 returned `OperationFailed`. Receipt:
  `/home/tmp2/gertullj/scratch/foundation-libs/text-contract-probes/htscodecs/epochs/after/hts-pack-corrected-after-debug/aggregate.json`.
  This is `OBSERVED` for those two cases. ReleaseSafe observed the same
  results from the already-compiled artifact after the parent established
  identical executable SDK inputs and probe files. Receipt:
  `/home/tmp2/gertullj/scratch/foundation-libs/text-contract-probes/htscodecs/epochs/after/hts-pack-safe-artifact-reuse/aggregate.json`.
  Its `ARTIFACT_REUSED` classification does not upgrade the earlier setup
  failure: that full-closure check saw four changed documentation files,
  not executable changes. Loaded dispatch, other alphabets and cross-target
  behavior are not claimed. No worker gate ran.

## 43. An advertised preset maximum is not the native table's upper bound

* **Condition.** `fqzcomp.compress` passes a signed strategy to the native
  parameter search.
* **Symptom.** `htscodecs/fqzcomp_qual.c:770-783` indexes a five-row table
  (`:195-203`), while `:751` clamps only indices at least 5. A negative
  index is not checked. `FQZ_MAX_STRAT` is 3
  (`htscodecs/fqzcomp_qual.h:50`), not the table's last index.
* **Fix.** The prose distinguishes the advertised presets from the custom
  row at 4. An ordinary `strat < 0` comparison now returns
  `InvalidArgument` before the native call; the native upper clamp remains.
* **Targets bound.** All targets and optimization modes, linked and loaded.
* **Verification.** The parent observed the Debug before probe aborting on
  native index -1 at `fqzcomp_qual.c:770`. Receipt:
  `/home/tmp2/gertullj/scratch/foundation-libs/text-contract-probes/htscodecs/epochs/before/hts-native-boundaries-before-3/fqz-strat-negative/result.json`.
* **After observation, 2026-10-04.** The parent's native static-linked
  consumer (`-Druntime=false`) compiled with exit 0 in Debug and
  ReleaseSafe. In both modes, strategy -1 returned `InvalidArgument`;
  strategies 0, 1 and 5 each compressed and decompressed to all 68
  original bytes, including the retained upper-clamp path at strategy 5.
  Aggregate receipts:
  `/home/tmp2/gertullj/scratch/foundation-libs/text-contract-probes/htscodecs/epochs/after/hts-guards-after-debug-20261004/aggregate.json`
  and
  `/home/tmp2/gertullj/scratch/foundation-libs/text-contract-probes/htscodecs/epochs/after/hts-guards-after-safe-20261004/aggregate.json`.
  This is `OBSERVED` focused behavior. The parent also observed the native
  linked SDK suites exit 0 in Debug and ReleaseSafe on 2026-10-04: 44/44
  tests in each, including both new edge regressions (changelog entry 21).
  The later eight-cell native linked matrix also executed all 44 tests
  without skips in all four optimization modes and both linkages, with
  smoke/install success; changelog entry 21 cites exact per-cell receipts.
  Loaded dispatch and cross targets remain pending. The complete focused
  probe drivers exited 1 on invalid scratch pack-fixture rows, not these
  fqz cases. No worker gate ran.

## 44. Narrow a native record count before adding sentinel capacity

* **Condition.** `qualStats` requires one extra `len` and `flags` entry and
  narrows `num_records` to the native `int`.
* **Symptom.** The old capacity comparison added 1 before narrowing.
  At `maxInt(usize)` that addition overflowed before the intended
  `LengthOverflow` refusal in the parent's Debug before probe.
* **Fix.** Narrow before the capacity comparison and reuse its result in
  `fqz_slice`. Keep the extra entries: the native selector-filter paths
  read `flags[rec]` and `len[rec]` before the record-bound comparison
  (`htscodecs/fqzcomp_qual.c:434-436`, `:533-534`). Their contents are passed
  through unchanged, not synthesized by the facade.
* **Targets bound.** All targets and optimization modes, linked and loaded.
* **Verification.** The parent observed the Debug before probe aborting on
  the sentinel-capacity addition in the facade. Receipt:
  `/home/tmp2/gertullj/scratch/foundation-libs/text-contract-probes/htscodecs/epochs/before/hts-native-boundaries-before-3/qual-stats-max-records/result.json`.
* **After observation, 2026-10-04.** The parent's native static-linked
  consumer (`-Druntime=false`) compiled with exit 0 in Debug and
  ReleaseSafe; `qual-stats-max-records` returned `LengthOverflow` in both.
  Aggregate receipts:
  `/home/tmp2/gertullj/scratch/foundation-libs/text-contract-probes/htscodecs/epochs/after/hts-guards-after-debug-20261004/aggregate.json`
  and
  `/home/tmp2/gertullj/scratch/foundation-libs/text-contract-probes/htscodecs/epochs/after/hts-guards-after-safe-20261004/aggregate.json`.
  This is `OBSERVED` for that boundary. The parent also observed the native
  linked SDK suites exit 0 in Debug and ReleaseSafe on 2026-10-04: 44/44
  tests in each, including both new edge regressions (changelog entry 21).
  The later eight-cell native linked matrix also executed all 44 tests
  without skips in all four optimization modes and both linkages, with
  smoke/install success; changelog entry 21 cites exact per-cell receipts.
  Loaded dispatch and cross targets remain pending. The complete focused
  probe drivers exited 1 on invalid scratch pack-fixture rows, not this
  case. No worker gate ran.
