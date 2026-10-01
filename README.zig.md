# htscodecs, packaged for Zig 0.16

This is a private downstream fork of
[samtools/htscodecs](https://github.com/samtools/htscodecs) at tag
**v1.6.7** (`b9fc194f772e45bb0a1f44b08cbf8697a1384bae`).  Upstream's own
`README.md` describes the codecs and the autotools build and is left
untouched; this file is the entry point for the Zig build.

The library is the real thing.  All the C sources under `htscodecs/` are
compiled unmodified: rANS 4x8, rANS 4x16, the 32x16 SIMD kernels, the
dynamic arithmetic coder, fqzcomp quality scores, the read-name tokeniser,
run-length coding and symbol packing.

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
| `zig build` | compile the library, install headers, run the source-integrity gate |
| `zig build test` | run the behavioural tests for the host target |
| `zig build test -Doptimize=ReleaseSafe` | the same, with safety checks and optimisations |
| `zig build smoke` | run the example, which checks itself against upstream's own fixtures |
| `zig build check` | compile the facade, tests and example for the six-target matrix; nothing is run |
| `zig build provenance` | the source-integrity gate: the licence and provenance records are present |
| `zig build provenance-history` | check that the pinned upstream commit is in this clone's git history |

Options: `-Dbz2=true`, `-Dcheck-targets=<list>`, `-Doptimize=`,
`-Dtarget=`, and `-fsys=htscodecs` for system-library mode.  That last
one is not a `-D` option: `b.systemIntegrationOption` is fed by the build
runner's `-fsys=`/`-fno-sys=` flags, so `-Dsystem=true` would be an unknown
option rather than a mode.

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

The exported names are `htscodecs` for both the module and the static
library artifact (`dep.module("htscodecs")`, `dep.artifact("htscodecs")`),
so a plain C consumer can link the artifact and use the installed headers
(the install step places all eleven under `include/htscodecs/` in the
install prefix, which is `zig-out/` by default) without taking the Zig
facade.  The module already links the artifact, which is why the snippet
above does not.

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

**`htscodecs.c` is the complete translated C interface.**  Every public
declaration of the eleven upstream headers this package installs is there,
including `utils.h` and `varint.h`, so nothing is hidden behind the facade.
Use it for anything the facade does not wrap.

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
| `rle` | `rle.c` | yes, both directions | no |
| `tok3` | `tokenise_name3.c` | no | **yes, on encode** |
| `pack` | `pack.c` | yes for `unpackTo` | no |

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

  No Zig allocator is involved, and no process-global allocator hook is
  installed to make upstream's `malloc` look like anything else.
* If you use the `c` module directly and get a pointer back, release it
  with `htscodecs.cFree`.

## Errors

`htscodecs.Error` has four members.  The line between them is whether *the
facade* knows the cause: an argument it inspects itself earns a name of its
own, and anything derived from a foreign `NULL` does not.

| Error | Meaning | Decided by |
|---|---|---|
| `LengthOverflow` | the length does not fit upstream's `unsigned int`; upstream rejects anything above `INT_MAX` too | the facade, before the call |
| `InvalidArgument` | an order byte the kernel does not implement, a record array that contradicts `Slice.num_records`, a symbol map under 256 bytes, or an input that overlaps the destination | the facade, before the call |
| `BufferTooSmall` | a zero-length destination, an `rle.encode` whose `run` or `out` is shorter than `data.len`, a `fqzcomp.decompressLengths` call given no room for the record lengths, or a stream `pack.unpackTo` would copy past its destination | the facade, by comparing the caller's own two lengths |
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
zero-length destination, the two `rle.encode` buffers, the
`pack.unpackTo` stream.  Size every other destination with the matching
`*CompressBound`, which removes the one cause a caller can act on.

`rle.encode` is the one place the bound is the wrapper's own rather than
upstream's: `hts_rle_encode` writes one literal per input byte into `out`
and one varint per run into `run` through an unbounded `var_put_u32`,
checking neither, so the facade requires `data.len` bytes in each and says
so.

## Aliasing

Every wrapper that takes a separate output buffer (`rans4x16.compressTo`,
`rans4x16.uncompressTo`, both `rans32x16` and both `arith` directions,
`rle.encode`, `rle.decode`, `pack.unpackTo`) returns
`error.InvalidArgument` when its input and output slices overlap.  Upstream
reads the input while writing the output, so overlapping regions would make
the result depend on the order the C code happens to touch the bytes.  The
check is an ordinary comparison that runs before the call in every build
mode, ReleaseFast and ReleaseSmall included: the public contract is that
error, and a guard that disappeared in a release build would stop keeping
the promise exactly where a caller is least able to notice.

## Outputs that are written before a call can fail

`pack.packData` fills `meta` — including the count at `meta_len` — before it
decides that the alphabet is too wide, so a failed call leaves a
plausible-looking map behind.  `meta` is meaningless when that call returns
`error.OperationFailed`, and the map may hold all 256 symbols even though
nothing was packed.  `Meta.map` is 257 bytes for the same reason: the C loop
writes `out_meta[n]` for the n-th used symbol before it rejects a wide
alphabet, which puts one byte past a 256-byte map.

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

## Inputs the codec writes

Two of the encoders destroy what you give them, and the signatures say so:
you cannot pass `const` data and you must pass memory you own.

* **`tok3.encodeNames(block: []u8, ...)`** replaces every `\n` or `\0`
  separator in the block with `\0` as it encodes
  (`tokenise_name3.c:1500`).  That is why upstream's `char *blk` is
  non-const.  Keep a copy if you still need the names, and never hand it a
  string literal.
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
reports it, and the build script does not guess in advance.  Nothing in this
table is an observed result; see `FORK-NOTES.md` for what has and has not
been run.

`-Dcheck-targets=` narrows the run.  Naming a default target builds only
those; naming a target from the opt-in list (`aarch64-macos`,
`x86_64-macos`, `aarch64-windows-gnu`) builds that one; naming something
the build does not recognise is an error, not a silent no-op.

Cross-target tests are compiled, not run.  `check` emits them as objects and
compiles the example into an executable without executing anything.

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
  its documented bound, the single-symbol unpack path reports only the bytes
  actually written, and the run-time kernel mask round trips in each configuration.
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
