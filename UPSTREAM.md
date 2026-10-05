# Upstream provenance

This fork is a packaging of upstream htscodecs.  Nothing in `htscodecs/`,
`tests/`, `javascript/`, `m4/`, `configure.ac`, `Makefile.am`, `README.md`,
`NEWS.md`, `BENCHMARKS.md`, `MAINTAINERS.md`, `LICENSE.md` or
`.gitattributes` was modified.  The single deliberate exception is
`.gitignore`: it keeps every upstream entry byte-identical and appends the
Zig build outputs.  See `CHANGELOG.md` entry 8.

## Pinned source

| | |
|---|---|
| Canonical URL | <https://github.com/samtools/htscodecs.git> |
| Upstream remote in this clone | `origin` → the URL above, fetch and push (see the publication note) |
| Tag | `v1.6.7` (annotated) |
| Tag object | `9f11619515c50186778c2820e8dbd322d78f24c2` |
| Commit | `b9fc194f772e45bb0a1f44b08cbf8697a1384bae` |
| Commit subject | `Make release 1.6.7` |
| Commit date | 2026-06-24T15:13:20+01:00 |
| Tag date | 2026-06-24T15:21:50+01:00 |
| `HTSCODECS_VERSION` | 100607 (1.6.7 encoded as XYYYZZ) |

## How the tree was obtained

```
git clone https://github.com/samtools/htscodecs.git
git -C htscodecs checkout v1.6.7
```

The clone brought the full upstream history; the checkout detached HEAD at
the tag rather than creating a branch, so no upstream commit was rewritten
and no upstream ref was renamed.  The default upstream branch is `master`;
this fork's own work is committed on top of the tag by the repository
owner.

Remote layout is still the clone's own: `origin` names
`https://github.com/samtools/htscodecs.git` for fetch *and* push, and no
downstream remote exists yet.  Before this tree is published, `origin` must
be repointed at the private downstream repository and the canonical URL
above must move to a remote named `upstream`, so that a push cannot reach
the upstream maintainer's repository by accident.  That change belongs to
the publishing step and has not been made; this file records the
requirement, not a performed action.

## How to verify the pin

Two steps, because two different things are being claimed.

`zig build provenance` is the source-integrity gate.  It fails if any of
`LICENSE.md`, `NOTICE.md`, `UPSTREAM.md`, `CHANGELOG.md`,
`include/htscodecs_all.h`, `include/htscodecs_config.h`,
`htscodecs/htscodecs.h` or `htscodecs/htscodecs.c` is missing.  That is a
property of the sources alone, so it runs offline, out of a tree with no
git at all, and it is part of every ordinary `zig build`.

`zig build provenance-history` is the clone gate.  It runs
`git cat-file -e b9fc194f772e45bb0a1f44b08cbf8697a1384bae^{commit}`, which
only succeeds while the pinned commit is still reachable in the preserved
history.  A source package fetched without `.git` therefore still builds.
Asked for where the history is absent, it fails rather than reporting a
success it did not observe.  Continuous integration runs both steps.

The workflow's provenance job then checks the records themselves: the pinned
commit still appears in `UPSTREAM.md` and `build.zig`, each of the three
upstream licence exceptions (`c_range_coder.h`, `rANS_byte.h`,
`rANS_word.h`) is still named in `NOTICE.md`, and a scoped `git diff`
against the pinned commit reports no change to any upstream C source,
header, test, script or licence path.  `.gitignore` is excluded from that
diff list because this fork appends to it (see below); the append is
recorded in `CHANGELOG.md` entry 8 rather than diffed byte for byte.  The
job finishes by copying the tree without `.git` and building it, so the
claim that a source package does not need git is a check rather than an
assertion.

One path in that list moved on 2026-10-04, and the list followed the bytes
rather than the name.  Upstream's `README.md` is preserved in this repository
as `README.upstream.md`; this fork's own README took over the `README.md`
path.  The pinned-commit diff therefore names `README.upstream.md`, so it
still compares upstream's README against upstream's README:

| Upstream path | Where its bytes are in this tree | sha256 |
|---|---|---|
| `README.md` at `b9fc194` | `README.upstream.md` | `b77d87e58c92f1aae4e74f8071c589ae23d424da82d2d73fa8434525be22de26` |

The digest was taken while both paths held the same bytes, immediately before
`README.md` was rewritten, so the preserved copy is a verified fact rather
than an assumption about a copy that might have been taken from the wrong
revision.  `NOTICE.md` §5 records the move and its licence consequences;
`CHANGELOG.md` entry 15 records the change.  `README.md` in this tree is
fork-authored prose and is covered by `FORK-LICENSE.md`.

## How to re-sync

```
git fetch origin
git checkout v1.6.7          # or the newer tag you want
```

Then update, in this order:

1. `configure.ac`'s `AC_INIT` version and `HTSCODECS_VERSION` in
   `htscodecs/htscodecs.h` come from upstream, so they move on their own.
2. `upstream_version` and `upstream_commit` in `build.zig`, which bake the
   tag into the generated `version.h` in place of upstream's
   `git describe`.
3. `fixtures.zig` if the new tag adds or removes anything under `tests/dat`
   or `tests/names`; the identifiers are mechanical, so regenerating them
   from a directory listing is enough.
4. The tables in `build.zig` (`matrix`, `required_files`) if the release
   changes the platform surface.
5. `CHANGELOG.md` and `FORK-NOTES.md`.

6. `README.upstream.md`, if the new tag changed upstream's README at all.
   Copy it before touching `README.md`, verify the digest, and update the
   table under "How to verify the pin".
7. `version` and the shared ABI triple in `package.nix` and
   `.github/workflows/verify.yml`.  The triple is libtool's
   `-version-info` from `configure.ac`, not the release version, so it moves
   when upstream changes its ABI policy and not merely when the tag does.
8. `NOTICE.md`'s per-file inventory, if the new tag adds or removes a
   licence exception.  A new public-domain or differently-licensed file has
   to be named there and in `FORK-LICENSE.md` §4 before it is compiled.

## Files this fork adds

| Path | Purpose |
|---|---|
| `build.zig`, `build.zig.zon` | Zig 0.16 build, replacing configure + make |
| `root.zig` | published module root |
| `src/htscodecs.zig` | idiomatic facade over the translated C |
| `include/htscodecs_all.h` | aggregate public header, vendored mode |
| `include/htscodecs_system.h` | aggregate public header, system mode |
| `include/htscodecs_config.h` | feature macros, shared by the C build and translate-c |
| `fixtures.zig` | upstream corpus embedded, generated from `tests/` |
| `test/*.zig` | behavioural tests |
| `examples/codec_demo.zig` | runnable demonstration, used by `zig build smoke` |
| `consumer/` | a separate package that depends on this one |
| `.github/workflows/verify.yml` | this fork's verification workflow |
| `README.zig.md` | the Zig interface: namespaces, ownership, errors, aliasing, and what the codec writes |
| `NOTICE.md`, `CHANGELOG.md`, `FORK-NOTES.md`, `UPSTREAM.md` | fork records |
| `README.md` | this fork's own README, in the order the contract fixes |
| `README.upstream.md` | upstream's `README.md`, preserved byte for byte (sha256 `b77d87e5…`) |
| `FORK-LICENSE.md` | the licence of the fork-authored files, and the authorization behind it |
| `package.nix` | standalone source-only Nix derivation; `static`, `shared` and `default` |
| `flake.nix` | flake outputs re-exporting `package.nix`, from a pinned nixpkgs input |
| `devenv.nix`, `devenv.yaml`, `.envrc` | the canonical development shell: tools and tasks, no built package |

## Files this fork modifies

| Path | Change |
|---|---|
| `.gitignore` | upstream's 47 entries unchanged, then an appended block for `.zig-cache/`, `zig-out/`, `zig-pkg/`, `result` and `result-*` (CHANGELOG entries 8 and 15) |

No other upstream path is modified.  The files below are removed outright:

## Files this fork removes

`.cirrus.yml`, `.github/workflows/unix-build.yml` and
`.github/workflows/windows-build.yml` are replaced by
`.github/workflows/verify.yml`.  The originals drive the build on the
upstream maintainer's own infrastructure (Cirrus CI and a Cirrus badge in
`README.md`) and describe an autotools build this fork does not use.  See
`CHANGELOG.md` entry 6.
