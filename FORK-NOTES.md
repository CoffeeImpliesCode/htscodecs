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
* **Fix.** `-Dsystem=true` switches the translation root to
  `include/htscodecs_system.h`, which includes the *installed* headers off
  the system include path.  Fork-only `htscodecs_config.h` is not included
  there, so the per-ISA 32x16 declarations stay hidden exactly when the
  installed build might not have them, and a missing declaration is a build
  error naming it rather than a link error later.
* **Rule.** Headers and library must come from the same source in any
  system-integration mode.
* **Verification.** unverified.

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
