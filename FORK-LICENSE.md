# Licence of fork-authored files

The repository owner authorized fork additions under BSD-3-Clause, matching htscodecs' primary upstream terms. Upstream files retain their own terms. Copyright for fork additions belongs to the contributors collectively; no individual or upstream author is named as holder.

SPDX identifier for fork-authored source and build files:

```
SPDX-License-Identifier: BSD-3-Clause
```

## Grant

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

## Covered paths

The grant covers these fork-authored files: `build.zig`, `build.zig.zon`, `root.zig`, `src/htscodecs.zig`, `include/htscodecs_all.h`, `include/htscodecs_system.h`, `include/htscodecs_config.h`, `fixtures.zig`, `test/fixture_decode_test.zig`, `test/roundtrip_test.zig`, `test/malformed_test.zig`, `test/facade_contract_test.zig`, `examples/codec_demo.zig`, `consumer/build.zig`, `consumer/build.zig.zon`, `consumer/src/main.zig`, `package.nix`, `flake.nix`, `devenv.nix`, `devenv.yaml`, `.envrc`, `README.md`, `README.zig.md`, `NOTICE.md`, `UPSTREAM.md`, `CHANGELOG.md`, `FORK-NOTES.md`, and `FORK-LICENSE.md`.

Only the appended Zig build-output block in `.gitignore` is covered; all 47 upstream entries are unchanged. `README.upstream.md` is a fork-created path containing upstream's `README.md` byte for byte, under upstream's terms.

## Upstream files and exceptions

The grant does not cover anything under `htscodecs/`, `tests/`, `javascript/` or `m4/`, or `configure.ac`, `Makefile.am`, `LICENSE.md`, `NEWS.md`, `BENCHMARKS.md`, `MAINTAINERS.md` or `.gitattributes`. These files are upstream v1.6.7 (`b9fc194f772e45bb0a1f44b08cbf8697a1384bae`) and retain upstream terms.

`htscodecs/c_range_coder.h` is public domain. `htscodecs/rANS_byte.h` and `htscodecs/rANS_word.h` are public domain under Fabien Giesen's CC0 waiver. `NOTICE.md` carries their texts; this grant adds no conditions and claims none of these files.

libbz2 is included only with `-Dbz2=true` or the Nix package's `bzip2` option. bzip2 1.0.6 has a BSD-like licence, not this fork's grant; it is disabled by default and is not enabled implicitly.
