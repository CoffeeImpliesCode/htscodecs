# Licence of the fork-authored files

`NOTICE.md` records what upstream's own terms are, per file.  This file
records the one thing those terms do not: the licence of the files *this
fork* wrote.

## 1. The authorization

The owner of this repository authorized a per-project licence for
fork-authored additions, matching the primary upstream terms.  htscodecs'
primary upstream terms are BSD-3-Clause, so the fork's own additions are
offered under BSD-3-Clause and no other grant.  Upstream's terms continue to
govern upstream's files.

SPDX identifier for every fork-authored file, for the header other roles add
to newly authored source and build files:

```
SPDX-License-Identifier: BSD-3-Clause
```

No individual is named as the copyright holder of the fork's additions; the
holder is the fork's contributors collectively.  Upstream authors are not
credited with fork work.

## 2. The grant

Copyright (c) 2026 htscodecs-fork contributors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

The same three clauses upstream's own `LICENSE.md` states, with the third
clause naming this fork's holder instead of Genome Research Limited.

## 3. What this grant covers

Every file in this repository that this fork wrote:

| Path | What it is |
|---|---|
| `build.zig`, `build.zig.zon` | the Zig 0.16 build graph and its manifest |
| `root.zig` | published module root |
| `src/htscodecs.zig` | the Zig facade over the translated C |
| `include/htscodecs_all.h` | aggregate public header, vendored build |
| `include/htscodecs_system.h` | aggregate public header, system-library build |
| `include/htscodecs_config.h` | target-conditional feature macros |
| `fixtures.zig` | mechanically generated from `tests/`; contains no hand-written bytes |
| `test/fixture_decode_test.zig` | behavioural test |
| `test/roundtrip_test.zig` | behavioural test |
| `test/malformed_test.zig` | behavioural test |
| `test/facade_contract_test.zig` | behavioural test |
| `examples/codec_demo.zig` | runnable demonstration |
| `consumer/build.zig`, `consumer/build.zig.zon`, `consumer/src/main.zig` | a separate package that depends on this one |
| `.github/workflows/verify.yml` | this fork's verification workflow |
| `package.nix` | standalone Nix derivation; `linkage` selects the variant |
| `flake.nix` | flake outputs re-exporting `package.nix` |
| `devenv.nix`, `devenv.yaml`, `.envrc` | the canonical development environment |
| `README.md` | this fork's README |
| `README.zig.md` | Zig interface documentation |
| `README.upstream.md` | upstream's `README.md`, preserved byte for byte; upstream's own terms, redistributed unmodified |
| `NOTICE.md`, `UPSTREAM.md`, `CHANGELOG.md`, `FORK-NOTES.md`, `FORK-LICENSE.md` | fork records |

`README.upstream.md` is listed because it is a fork-created *path*.  Its
bytes are upstream's and its terms are upstream's; see `NOTICE.md` §1.

## 4. What this grant does not cover

Nothing under `htscodecs/`, `tests/`, `javascript/` or `m4/`, and not
`configure.ac`, `Makefile.am`, `LICENSE.md`, `NEWS.md`, `BENCHMARKS.md`,
`MAINTAINERS.md` or `.gitattributes`.  Those are upstream v1.6.7
(`b9fc194f772e45bb0a1f44b08cbf8697a1384bae`) and their terms are upstream's,
unchanged by anything in this file.

`.gitignore` is a mixed path and is recorded as such: all 47 of upstream's
entries are upstream's and are untouched, and the appended block covering the
Zig build outputs is fork work covered by the grant above
(`CHANGELOG.md` entry 8, `FORK-NOTES.md` entry 19).

Three files are neither upstream's BSD nor fork work: `htscodecs/c_range_coder.h`
is public domain, and `htscodecs/rANS_byte.h` and `htscodecs/rANS_word.h` are
public domain under Fabien Giesen's CC0 waiver.  `NOTICE.md` §2 carries their
text.  A public-domain dedication carries no conditions, so the grant above
neither adds any to them nor claims them.

## 5. Third-party material the build may pull in

libbz2, and only when the build is given `-Dbz2=true` or the Nix package is
given `bzip2`.  bzip2 is distributed under a BSD-like licence
(`bzip2-1.0.6`), asserted by that package and not restated as this fork's
grant.  It is off by default and nothing in this repository enables it
implicitly.
