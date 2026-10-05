# htscodecs, packaged for Zig 0.16

This is a private downstream fork of
[samtools/htscodecs](https://github.com/samtools/htscodecs) at tag
**v1.6.7** (`b9fc194f772e45bb0a1f44b08cbf8697a1384bae`).

`README.md` is the entry point: what deviates from upstream, what the build
matrix currently is, and how to consume it.  This file is the interface
documentation — namespaces, ownership, errors, aliasing, the inputs the codec
writes into — and deliberately says nothing about the build's status.
Upstream's own README is preserved byte for byte as `README.upstream.md`.

The library is the real thing.  All the C sources under `htscodecs/` are
compiled unmodified: rANS 4x8, rANS 4x16, the 32x16 SIMD kernels, the
dynamic arithmetic coder, fqzcomp quality scores, the read-name tokeniser,
run-length coding and symbol packing.

One fact about that source set is not a summary but a caller-visible boundary,
so it is documented here rather than left to be discovered at link time: one
of the functions those headers declare has no implementation at this pin.
Upstream disabled it and this fork does not re-enable it, substitute for it
or hide the declaration.  See
[The one declaration with no implementation](#the-one-declaration-with-no-implementation).

* `README.md` — the fork's own README: deviations, matrix, consumption
* `README.upstream.md` — upstream's README, unmodified
* `FORK-LICENSE.md` — the licence of the fork-authored files
* `UPSTREAM.md` — the exact pinned source, how it was obtained, how to
  re-sync, and the provenance gate.
* `CHANGELOG.md` — every divergence from upstream, numbered.
* `NOTICE.md` — upstream's BSD terms, the public-domain and CC0 components,
  and what this fork adds.
* `FORK-NOTES.md` — issues met while designing the build, with cause and
  reusable rule.

## Build and run

| Command | What it does |
|---|---|
| `zig build` | compile the library, install the headers, the example, `htscodecs.pc` and the licence and documentation material, and run the source-integrity gate |
| `zig build test` | run the behavioural tests for the host target |
| `zig build test -Doptimize=ReleaseSafe` | the same, with safety checks and optimisations |
| `zig build smoke` | run the example, which checks itself against upstream's own fixtures |
| `zig build check` | compile the facade, tests and example for the six-target matrix; nothing is run |
| `zig build provenance` | the source-integrity gate: the licence and provenance records are present |
| `zig build provenance-history` | check that the pinned upstream commit is in this clone's git history |
| `HTSCODECS_PROVIDER=<provider> zig build test -Druntime=true -Dlinkage=static` | the same tests with every native symbol resolved through the generated dispatch at run time; nothing native is linked into the test binary |
| `HTSCODECS_PROVIDER=<provider> zig build test -Druntime=true -Dlinkage=dynamic` | the same, against a shared provider |
| `zig build check-shared` | the same six-target matrix against the shared graph; `wasm32-wasi` is refused there because its OS has no dynamic linker |

Options: `-Dlinkage=static|dynamic`, `-Druntime=true`, `-Dbz2=true`,
`-Dcheck-targets=<list>`, `-Doptimize=`, `-Dtarget=`, and
`-fsys=htscodecs` for system-library mode.
The linkage default is `static`, which is the policy this build had before the
option existed, and `-Druntime=true` is orthogonal to it: it changes how the
symbols are *reached*, not which artifact is built.  `-Druntime=true` and
`-fsys=htscodecs` cannot be combined, because system mode publishes the
installed library's own headers and has no translation of its own to generate
a dispatch from.  That last option is not a `-D` option:
`b.systemIntegrationOption` is fed by the build runner's `-fsys=`/`-fno-sys=`
flags, so `-Dsystem=true` would be an unknown option rather than a mode.
`-Dlinkage=dynamic` is refused for a target whose OS has no dynamic linker,
which in this matrix means `wasm32-wasi`: the build stops at configure time
naming the target and the reason, and inside `zig build check-shared` that one
row becomes a failing step carrying the same text while the other five rows
are still compiled.  Nothing is substituted for the shared object that was
asked for, and no row is dropped from the matrix.

`HTSCODECS_PROVIDER` is the only thing a runtime-loading test run reads to
find its provider, and `test/provider.zig` is the only file that reads it.
There is no default location, no search path and no fallback to a system
library; a run in that configuration that was not told which provider to load
fails rather than passing vacuously.  Which of these rows has actually been
run, and on which host, is recorded in `README.md`'s matrix — this file does
not carry gate results.

The comment at `include/htscodecs_system.h:5` still says `-Dsystem=true`.
It is stale. The build reads `b.systemIntegrationOption`, so use
`-fsys=htscodecs`, not the unknown `-Dsystem=true` option.

`-fsys=htscodecs` links an installed `libhtscodecs` instead of compiling the
vendored one, and translates the *installed* headers rather than this tree's,
so the declarations and the linked library come from the same place.  In
that mode `zig build test` runs the fixture-decoding test against the system
library: an installed htscodecs has to decode upstream's own checked-in
streams, which is the claim that matters there.  `check`, `smoke` and the
`provenance-history` step are vendored-mode entry points; a missing
declaration in an older installed header is a build error naming it, not a
link error later.  This fork's own `htscodecs_config.h` is not used in system
mode, so the per-ISA 32x16 entry points stay hidden exactly when the
installed library may not have been built with them.

## Using it from another package

```zig
// build.zig.zon
.dependencies = .{
    .htscodecs = .{ .path = "../htscodecs" },
},

// build.zig
const dep = b.dependency("htscodecs", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("htscodecs", dep.module("htscodecs"));
```

The exported names are `htscodecs` for both the module and the library
artifact (`dep.module("htscodecs")`, `dep.artifact("htscodecs")`), so a
plain C consumer can link the artifact and use the installed headers without
taking the Zig facade.  The artifact is static unless the dependency is
asked for `-Dlinkage=dynamic`, and the installed include tree is thirteen
headers: the eleven upstream headers whose symbols this build compiles, plus
this fork's aggregate and configuration header, all under `include/htscodecs/`
in the install prefix (`zig-out/` by default).  The module already links the
artifact, which is why the snippet above does not.

```zig
// src/main.zig
const htscodecs = @import("htscodecs");

const payload = "the quick brown fox jumps over the lazy dog" ** 8;

// Caller buffers: nothing is allocated by the library.
const bound = try htscodecs.rans4x16.compressBound(payload.len, 0);
const scratch = try allocator.alloc(u8, bound);
defer allocator.free(scratch);
const n = try htscodecs.rans4x16.compressTo(payload, scratch, 0);

// Size the decode destination to the payload, not to a round number.  A
// STRIPE stream is rejected outright if the destination is *larger* than
// the original, so an over-sized buffer is a real failure, not slack.
const plain = try allocator.alloc(u8, payload.len);
defer allocator.free(plain);
const m = try htscodecs.rans4x16.uncompressTo(scratch[0..n], plain);
assert(std.mem.eql(u8, plain[0..m], payload));

`consumer/` in this repository is exactly that, as a real separate package:
`cd consumer && zig build run`.

## The two interfaces

**`htscodecs.c` is the complete translated C interface.**  Every declaration
the eleven upstream headers this package installs expose to the configured
target is there, including `utils.h` and `varint.h`, so nothing is hidden
behind the facade.  Use it for anything the facade does not wrap.

Read that as a claim about declarations and not about implementations,
because at this pin exactly one declared name has no implementation behind
it.  See [The one declaration with no implementation](#the-one-declaration-with-no-implementation)
below for the name, the two places it is honoured, and what happens when a
consumer calls it.  Nothing in this package covers part of what that
function would have done, and nothing here presents a stand-in as though it
were upstream's.

The aggregate header includes each of them as upstream wrote it.  It does
not redefine the `static` keyword around any include: `fqzcomp_qual.h`
carries `static const int` file-scope constants and also includes
`<stdint.h>` inside its own guard, so a `#define static` window would turn
every `static` in that system header — and in anything else pulled in beside
it — into an external definition.  Those constants stay internal-linkage
constants, which is what the generated Zig code sees.

**The namespaces are the convenience layer.**  They pick the right upstream
entry point, refuse lengths upstream could not accept, and make buffer
ownership explicit.

| Namespace | Upstream header | Caller buffers? | Writes its input? |
|---|---|---|---|
| `rans4x8` | `rANS_static.h` | no, upstream has no `*_to` form | no |
| `rans4x16` | `rANS_static4x16pr.h` | yes, both directions | no |
| `rans32x16` | `rANS_static32x16pr.h` | yes, both directions | no |
| `arith` | `arith_dynamic.h` | yes, both directions | no |
| `fqzcomp` | `fqzcomp_qual.c` | no | **yes, on encode** |
| `rle` | `rle.c` | yes, both directions | no; `encode` does update the caller's `Symbols` in place |
| `tok3` | `tokenise_name3.c` | no | **yes, on encode** |
| `pack` | `pack.c` | yes: the `unpackMeta` map and the `unpackTo` destination | no |

## Ownership

* Where upstream has a `*_to` entry point, the facade writes into your
  buffer and returns the number of bytes used.  No allocation, nothing to
  free.
* Where upstream only offers a `malloc`ing entry point, the facade returns
  an `Owned`, which is upstream's own pointer wrapped:

  ```zig
  const encoded = try htscodecs.rans4x8.compress(data, 0);
  defer encoded.deinit();   // calls std.c.free, the allocator that produced it
  use encoded.slice();
  ```

* An `Owned` is a single-owner handle with no copy protection.  Copying the
  struct copies the pointer, both copies name the same block, and `deinit`
  frees it - so release it exactly once, on one copy, and never on a copy
  and its original, which is a double free.  `deinit` is not idempotent.
  `slice()` is a window on the block rather than a copy of it, so it
  dangles the moment `deinit` runs.
* Nothing here touches a Zig allocator, and no process-global allocator
  hook is installed to make upstream's `malloc` look like anything else.
  That also means `std.testing.allocator` cannot see these bytes: a leak
  oracle over Zig allocations does not cover an `Owned`.  No allocator
  argument is needed or accepted, and an `Owned` may be built in one
  context and released in another.
* The buffers upstream hands *back* are plain libc `malloc` blocks, which is
  exactly why `deinit` uses `std.c.free`.  That is a different allocator
  family from `htscodecs_tls_alloc` / `htscodecs_tls_calloc` /
  `htscodecs_tls_free` (`htscodecs/utils.h:66-68`), which is upstream's
  internal per-thread scratch pool and which the facade never exposes.  With
  pthreads those buffers recycle through a `pthread_key_t` pool created under
  `pthread_once` (`htscodecs/utils.c:103-135`), and `htscodecs_tls_free`
  decides pool-versus-heap by querying that key, so handing one to libc
  `free` is not equivalent.  Under `NO_THREADS` — which
  `include/htscodecs_config.h:99-103` selects for `wasm32-wasi` — the same
  three names are plain `calloc`/`free`.  `README.md` states the same fact
  for C and dynamic-loading consumers.
* If you use the `c` module directly and get a pointer back, release it
  with `htscodecs.cFree`.

## Errors

`htscodecs.Error` has four members.  The line between them is whether *the
facade* knows the cause: an argument it inspects itself earns a name of its
own, and anything derived from a foreign `NULL` does not.

| Error | Meaning | Decided by |
|---|---|---|
| `LengthOverflow` | a caller length, or a record count, that does not fit the narrower type upstream's prototype takes for it; upstream rejects anything above `INT_MAX` too | the facade, before the call |
| `InvalidArgument` | an order byte the kernel does not implement, a negative fqzcomp strategy, a record array that contradicts `Slice.num_records`, a symbol map under 256 bytes, an `rle.Symbols` count outside 0..256, or an input/output pair a wrapper below names as unsafe to overlap | the facade, before the call |
| `BufferTooSmall` | a zero-length destination, an `rle.encode` whose `run` or `out` is shorter than `data.len`, a `fqzcomp.decompressLengths` call given no room at all for the record lengths, or a stream `pack.unpackTo` would copy past its destination | the facade, by comparing the caller's own two lengths |
| `OperationFailed` | upstream returned NULL and the C API does not say why | upstream |

`OperationFailed` names no cause because none is recoverable.  A NULL from
any of these entry points may mean the stream was malformed, the capacity
was insufficient, the method is compiled out (the arithmetic coder's `ext`
without `-Dbz2=true`), or an allocation failed, and `htscodecs.c` collapses
all four into one return value.  That is also why a nonzero destination
upstream rejected is never reported as `BufferTooSmall`: a caller told to
retry with a bigger buffer would loop forever against an allocation failure
or a compiled-out method.  The facade reports `BufferTooSmall` only where it
compared two of the caller's own lengths and knows the answer — a
zero-length destination, the two `rle.encode` buffers, the empty
`decompressLengths` array, the `pack.unpackTo` uncompressed (`nsym == 1`)
copy. Size compression destinations with the matching `*CompressBound`.
For `pack.unpackTo`, retain the exact unpacked size separately: packed bits
alone do not retain it, and the facade does not validate `out.len` against
that original size. A native NULL, including a packed-input length rejection,
is `OperationFailed`, not `InvalidArgument` or `BufferTooSmall`.

`fqzcomp.compress` rejects only negative strategy indices. The exported
`max_strategy` retains upstream's advertised preset maximum 3; the native
table also has a custom row at 4 and clamps indices at least 5 to that row.
`fqzcomp.qualStats` narrows `num_records` before adding its required extra
array entry, so an unrepresentable record count returns `LengthOverflow`
before the sentinel-capacity check.

`rle.Symbols.count` is checked against the 256 entries of `rle.Symbols.syms`
before either direction calls C, because upstream indexes that array with
the caller's own count and nothing else (`rle.c:112-114` encodes,
`rle.c:155-156` decodes).  `0` on entry to `rle.encode` still means "survey
the data and fill in the set" (`rle.c:115-118`) and `256` is still the last
accepted count; anything outside that range is `error.InvalidArgument`, and
no caller buffer is touched.

`rle.encode` is the one place the bound is the wrapper's own rather than
upstream's: `hts_rle_encode` writes one literal per input byte into `out`
and one varint per run into `run` through an unbounded `var_put_u32`,
checking neither, so the facade requires `data.len` bytes in each and says
so.

## Aliasing

The overlap guard runs in exactly these places, and each is an ordinary
comparison made before the call in every build mode, ReleaseFast and
ReleaseSmall included: the public contract is that error, and a guard that
disappeared in a release build would stop keeping the promise exactly where
a caller is least able to notice.

| Call | Refused pair |
|---|---|
| `rans4x16.compressTo`, `arith.compressTo` | `in` against `out` |
| `rans4x16.uncompressTo`, `arith.uncompressTo` | `compressed` against `out` |
| `rans32x16.compressTo`, `rans32x16.uncompressTo` | the input against `out` |
| `rle.encode` | `data` against `run`, and `data` against `out` |
| `rle.decode` | `lit` against `out`, and `run` against `out` |
| `pack.unpackTo` | `data` against `out` |
| `fqzcomp.decompressLengths` | `compressed` against `lengths` |

That list is the whole checked claim. These mutable pairs are not compared:
`rle.encode`'s `run` against `out`, `pack.unpackTo`'s `map` against `out`,
`pack.unpackMeta`'s `data` against `map`, and `pack.packData`'s `data` against
`meta.map`. Give each pair separate storage. `packData` reads input both before
and after writing metadata (`htscodecs/pack.c:63-70`, `:98-100`).

`fqzcomp.compress` mutates its input, lengths and flags. Give those three
buffers separate storage too. `rle.decode`'s two read-only inputs may share.
Wrappers with only an allocated result have no caller-provided output buffer
to compare, but that does not imply their mutable input/metadata can alias.

## Outputs that are written before a call can fail

`pack.packData` fills `meta` — including the count at `meta_len` — before it
decides that the alphabet is too wide, so a failed call leaves a
plausible-looking map behind.  `meta` is meaningless when that call returns
`error.OperationFailed`, and the map may hold all 256 symbols even though
nothing was packed.  `Meta.map` is 257 bytes for the same reason: the C loop
writes `out_meta[n]` for the n-th used symbol before it rejects a wide
alphabet, which puts one byte past a 256-byte map.

`fqzcomp.decompressLengths` fills `lengths` one record at a time as it
decodes (`fqzcomp_qual.c:1419`), so a call that returns
`error.OperationFailed` partway through leaves the entries it had already
written in place, indistinguishable from whatever the caller had put there.
Its `lengths` array length is also the bound handed upstream as `nlengths`,
so a block with more records than the array holds decodes successfully and
simply leaves the tail lengths absent rather than reporting an error.

## Optional bzip2

The arithmetic coder's `ext` method (`arith_order_flag.ext`, byte 0x04)
delegates a block to bzip2.  It is compiled in only with `-Dbz2=true`, which
also links `-lbz2`; the default build leaves it out, matching upstream on a
machine without libbz2.  Without it, both directions fail for such a stream
and surface as `error.OperationFailed`, which is the same answer every other
unexplained NULL gets.  Upstream's own `tests/dat/arith/u32.4` is one of
those streams, so a default build can read every other checked-in fixture
and not that one; `test/fixture_decode_test.zig` accepts either outcome for
it and checks the bytes only when the method is present.

## Kernel selection

`htscodecs.ransSetCpu` restricts which 32x16 kernels the library may pick at
run time, and it *replaces* the mask instead of merging with it:
`htscodecs.cpu_flag.none` (0) forces the scalar 4-way path, and
`htscodecs.cpu_flag.all` (0xFFFF) is what restores automatic detection —
passing 0 does not.  The mask affects only the 32x16 entry points reached
through `rans4x16`; a round trip must reproduce the input in either
configuration, which `test/roundtrip_test.zig` asserts.

The mask is not the whole story: at this pin there is no SSE4 order-0
*encoder* to select, so that tier resolves to the scalar kernel however the
mask is set.  The next section gives the name, the source evidence and what a
direct call to it does.

## The one declaration with no implementation

At this pin exactly one name the installed headers declare has no definition
this build compiles.  It is named here rather than left as a general warning,
because "some symbols may be absent" is exactly the sentence that hides a
fabricated stand-in.

* **`rans_compress_O0_32x16_sse4`**, declared at `rANS_static32x16pr.h:83`-`:86`
  under `HAVE_SSE4_1 && HAVE_SSSE3 && HAVE_POPCNT` — so on `x86_64`, where
  `include/htscodecs_config.h:74`-`:90` defines those macros, and on no other
  target.  The only definition upstream wrote sits inside an `#if 0` block at
  `rANS_static32x16pr_sse4.c:113`-`:460`, under upstream's own reason at
  `:111`-`:112`: "SSE4 implementation of the Order-0 encoder is poorly
  performing.  Disabled for now."  This fork leaves that `#if 0` exactly as
  pinned.  Re-enabling it would be a native-source change, and writing a
  replacement would be a different library under upstream's name, so neither
  is done here.

Everything else the configured headers declare is implemented, and is
required.  Reading the eleven installed upstream headers gives 46 function
declarations; the target-derived subset a configuration actually exposes is
42 on `x86_64` — the four Neon declarations are hidden there — 35 on
`aarch64`, and 31 on `riscv64` and `wasm32`, and in each of those sets every
name but the one above has a definition this build compiles.  That includes
both SSE4 *decoders*, all four AVX2 kernels, all four AVX512 kernels and all
four Neon kernels.  In a `-Druntime=true` build every one of those is
required: a provider that does not export one of them is refused when it is
loaded, rather than being used for the half of the library it does have.

What a call to the one missing name does depends on the configuration, and
both answers are refusals rather than approximations:

* **Runtime-loaded** (`-Druntime=true`): it is the only optional entry in the
  dispatch table (`runtime/graph.zig`, `provider_optional`).  A provider that
  does not export it still loads and every other codec works; the table field
  simply stays null.  Calling it stops the process with

  ```
  htscodecs: the loaded provider does not export rans_compress_O0_32x16_sse4, which rans_compress_O0_32x16_sse4 needs; this provider is not the library this build describes
  ```

  That is an ordinary panic in every optimisation mode, like the panic for a
  call made before `load`.  No scalar kernel is substituted, no retry is
  attempted, and no other codec is refused because one optional field is
  empty.
* **Linked** (the default): there is no table, so the call is a direct
  reference to a name no object in this build's archive defines.  Your
  program fails to link unless it supplies its own external definition of
  that exact name, with the caller's own signature and the caller's own
  behaviour.  This package manufactures none on purpose: a stand-in that
  returned something plausible would be a function upstream never wrote,
  published under upstream's name.  The generated Windows export definition
  for the shared variant is built from what each kernel source *defines*, so
  it names only `rans_uncompress_O0_32x16_sse4` and
  `rans_uncompress_O1_32x16_sse4` for this ISA and no encoder.

The library's own kernel selection never needs the missing function, and that
is upstream's code rather than this fork stepping around it.  Upstream's
*encoder* dispatcher gates an SSE4 tier but hands it the scalar kernel
(`rANS_static4x16pr.c:1001`-`:1004` for order 0, `:987`-`:990` for order 1),
while its *decoder* dispatcher does select the SSE4 decoders (`:1052`,
`:1066`).  So an SSE4-only machine encodes 32x16 with the scalar code and
decodes with SSE4, exactly as upstream intends, and the missing name is never
referenced by anything this build links.

## Inputs the codec writes

Two of the encoders destroy what you give them, and the signatures say so:
you cannot pass `const` data and you must pass memory you own.

* **`tok3.encodeNames(block: []u8, ...)`** replaces every `\n` or `\0`
  separator in the block with `\0` as it encodes
  (`tokenise_name3.c:1500`).  That is why upstream's `char *blk` is
  non-const.  Keep a copy if you still need the names, and never hand it a
  string literal.
  A failed call can leave the block half-rewritten, and `last_start` is
  written by upstream exactly once, after it has scanned the whole block
  (`tokenise_name3.c:1482`-`:1483`), so on failure it can hold either your
  own previous value or a stale offset.  Treat it as meaningful only when
  the call succeeded.
* **`fqzcomp.compress(vers, slice, in: []u8, strat)`** rewrites all three
  inputs: it clamps `slice.len` so the records sum to `in.len`
  (`fqzcomp_qual.c:790`, `:795`), ORs its chosen selector into
  `slice.flags` (`:589`, `:596`), and for a `vers_3_1` stream
  reverses flagged records of `in` before encoding (`:763` sets
  `GFLAG_DO_REV`, `:1087`-`:1109` act on it). The success path reverses them
  back (`:1193`-`:1217`); an early failure can leave input bytes changed.
  A `vers_4_0` stream leaves quality bytes alone. Length and flag arrays can
  still change on success.

`Slice.len` and `Slice.flags` are therefore `[]u32`, not `[]const u32`.
The other six namespaces leave their inputs alone.

## Cross-target matrix

`zig build check` compiles the C core, the translated interface, every
public facade method, the tests and the example for:

| Target | What `check` does with it |
|---|---|
| `x86_64-linux-gnu` | compiles the SSE4.1, AVX2 and AVX-512 32x16 kernels alongside the scalar core |
| `aarch64-linux-gnu` | compiles the Neon 32x16 kernel alongside the scalar core |
| `aarch64-macos-none` | compiles the scalar core and the Neon 32x16 kernel; in Zig 0.16 `Abi.default` maps `.macos` to `.none`, so this is the ordinary macOS ABI, not a libc-less one |
| `x86_64-windows-gnu` | compiles the scalar core and the three x86 kernels |
| `riscv64-linux-gnu` | compiles the scalar core |
| `wasm32-wasi` | compiles the scalar core with `NO_THREADS` |

The matrix names all six.  The build script does not pre-judge any of them:
if a target turns out to need something this machine does not have, the gate
reports it, and the build script does not guess in advance.  `zig build check`
over all six has been observed twice — 2026-10-04, exit 0, 66/66 steps, and
2026-10-05 as the whole-graph compile-only baseline
`baseline-htscodecs-check`, exit 0, `Build Summary: 66/66 steps succeeded`,
`failed: false`, all six targets seen and not one diagnostic line in the
output (epoch `20261005T014547Z-797a73f2`) — so every row in the table above
really was compiled, `wasm32-wasi` included.  That baseline is compile-only by
its own declaration (`runtime_pass_claimed: false`) and contributes no runtime
evidence; the receipts, and the status of everything this table does not cover,
are in `README.md`'s build matrix; `FORK-NOTES.md` says what has and has not
been run.

`-Dcheck-targets=` narrows the run.  Naming a default target builds only
those; naming a target from the opt-in list (`aarch64-macos`,
`x86_64-macos`, `aarch64-windows-gnu`) builds that one; naming something
the build does not recognise is an error, not a silent no-op.

`zig build check-shared` walks those same six names against the shared graph,
and one of them is not built.  `wasm32-wasi`'s OS has no dynamic linker, so
there is no shared object it could carry, and `build.zig` makes that row a
named failing step carrying the reason instead of dropping the name or
substituting a static archive.  The other five rows are still compiled, the
static matrix above is a separate step and is unaffected, and the default
`-Dlinkage=static` delivery for `wasm32-wasi` is unchanged.

That boundary has been observed too, twice.  2026-10-04, `zig build check-shared`
over all six exited 1 with exactly one failed step — the refusal, naming
`wasm32-wasi` and the reason — while the five hosted rows compiled; selecting
those five by name exits 0 with 59/59 steps, and the same five with
`-Druntime=true` exits 0 with 41/41.  2026-10-05, the whole-graph compile-only
baseline `baseline-htscodecs-check-shared` reproduced exactly that: exit 1,
`failed: true`, `Build Summary: 58/60 steps succeeded (1 failed)`, all six
targets seen and none missing, the one failure the `wasm32-wasi` refusal and
the rest compiled, with an empty prefix inventory (epoch
`20261005T014547Z-797a73f2`).  That exit 1 is the intended refusal inside a
compile-only baseline — not a compiler failure, not a regression, and not a
runtime result.  Nothing here claims a shared `wasm32-wasi` library, because
there is none to build.

Cross-target tests are compiled, not run.  `check` emits them as objects and
compiles the example into an executable without executing anything.

The wider 53-target cross-test gate over this same tree has now been run too:
epoch `20261004T221720228710Z-45046`, receipt `htscodecs-53-target-8.json`,
`source_unchanged: true`, `jobs_honoured: true`.  Of 53 targets, **18 are
runtime passes** (`tests=44`, `reason=tests_complete`), **31 are `build_only`** —
compiled and never executed, because no runner exists for them — and **4 fail**,
so the driver exits 1.  Two of those four are runtime failures
(`tests_failed`, run exit 1, 44 tests reported): `aarch64_be-linux` and
`thumbeb-linux`, both of which build, link and execute before disagreeing with
the reference bytes.  The other two are build failures (`build_failed`, build
exit 1, run never reached — `run.status: not_run`): `aarch64-netbsd` and
`aarch64_be-netbsd`.  A build failure is not a runtime failure, and
`build_only` is compiled-but-not-run, so "53 targets built" is not "53 tests
passed" and is not written as one anywhere in this package.

What the tests themselves have covered, on the host, is three eight-cell
waves — four optimisation modes by two linkages — and every cell in each is a
runtime pass: native linked, `-Druntime=false`, 8/8 (epoch
`20261004T233628757747Z-69351`); own-loaded, `-Druntime=true` against this
tree's own provider, 8/8 (epoch `20261004T232823091897Z-23133`); and against an
accepted **external** provider, `/usr/lib64/libhtscodecs.so.2.1.4` (sha256
`55f11ac88673ba6c0af07e614fb6a1d9e6344c62781918c8f8a21a20a3035882`), 8/8 with
`50/50 steps succeeded; 44/44 tests passed`, `skip_sites: []`, exit 0 in each
cell (epoch `20261004T233121760876Z-12541`).  That last wave is real
independent external coverage — the provider was accepted as
`kind: compatible-external` on route `path-02-libhtscodecs.so.2.1.4-success`
(producer receipt `htscodecs-index.json`, epoch `20261004T232439Z`) — whereas the
own-loaded wave's independence is `own` and proves the loaded route only.

One change in the current graph is **applied and not yet re-gated**.  An earlier
positive system-library wave failed with fixed-width / `size_t` undeclared in the
translated surface: this fork's private aggregate header for that mode left
those types undeclared.  It now includes the standard headers that declare them,
the `<stdint.h>` / `<stddef.h>` family in `include/htscodecs_system.h`, while
the native aggregate header `include/htscodecs_all.h` is untouched; it lands
with the selected-platform-configuration fix and the removal of the empty shim.
**No receipt re-runs htscodecs after this fix**, so no cell above is promoted on
its account and none of those earlier failing cells is recorded as a pass.
Settling it needs a fresh run of this SDK's own gates after the fix.

## What the tests check

* **Independent oracles.**  Upstream checks in two separate artifacts for
  every corpus entry: the plain input under `tests/dat` or `tests/names`,
  and the compressed stream its own encoders produced from it under
  `tests/dat/r4x8`, `r4x16`, `arith`, `fqzcomp` or `tests/names/tok3`.  The
  tests decode the checked-in stream and compare the bytes against the
  checked-in plain input, so the oracle is upstream's encoder and its own
  post-processing, not ours — a round trip with our own encoder could pass
  with both sides wrong together, and this cannot.  All 218 files (97 under
  `tests/dat`, 121 under `tests/names`) are embedded; the uncompressed side
  is derived exactly as upstream's shell tests derive it: column 1 of each
  tab-separated line with the line terminators removed (`cut -f 1 | tr -d
  '\012'`) for quality data, and `tr '\000' '\012'` for names.
* **Encode/decode compatibility** for every order and method flag, and the
  equivalence of the caller-buffer and owned paths — which is what catches
  a wrapper that forgets to write the used length back.
* **Bounded malformed input**: empty and runt streams are rejected, an
  undersized destination is reported rather than overrun, and truncated or
  single-byte-damaged streams never reproduce the original.
* **Facade contracts**: length narrowing and overlapping buffers are refused
  before the call, `rle.encode` refuses a `run` or `out` one byte short of
  its documented bound, an `rle.Symbols` count outside 0..256 is refused in
  both directions with `run`, `out` and the symbol map left byte-identical
  while 0 and 256 still round-trip, the single-symbol unpack path reports
  only the bytes actually written, and the run-time kernel mask round trips
  in each configuration.
* **How `check` proves the facade compiles.**  The tests are the
  deliberate callers: each public method is invoked by a test that asserts
  something about its result, and `check` compiles those tests for the
  target, which is what instantiates the method bodies.  Reflection is not
  used as the mechanism — resolving a declaration's type says nothing
  about whether its body type-checks, and a reflection-only test can only
  ever pass.

Deliberately not tested: the version string and other default constants.  A
test that asserts `version() == 100607` only restates the pin recorded in
`UPSTREAM.md` and `CHANGELOG.md` entry 7, and would need editing on every
release.  `zig build smoke` prints it, `zig build provenance` requires the
records that carry it to be present, and `zig build provenance-history`
requires the pinned commit to be in the clone — three checks that a
constant is recorded and reachable, none of which is a test of the facade's
behaviour or a substitute for one.

## Fixture provenance

Every byte under `tests/dat` and `tests/names` comes from upstream at tag
v1.6.7.  `fixtures.zig` embeds them with `@embedFile` and adds nothing.
`qualityPayload` reproduces upstream's `cut -f 1 < file | tr -d '\012'`,
which is how upstream's shell tests derive the uncompressed side of every
fixture; `splitNames` reproduces `tr '\000' '\012'`.  The mapping from
fixture path to Zig identifier is listed at the top of that file.
