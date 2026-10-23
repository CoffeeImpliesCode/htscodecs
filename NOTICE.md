# NOTICE

## Upstream licence

All upstream files are copyright Genome Research Limited and licensed under the BSD terms below, except the three public-domain files listed in the inventory.

> Redistribution and use in source and binary forms, with or without
> modification, are permitted provided that the following conditions
> are met:
>
>     (1) Redistributions of source code must retain the above copyright
>     notice, this list of conditions and the following disclaimer.
>
>     (2) Redistributions in binary form must reproduce the above
>     copyright notice, this list of conditions and the following
>     disclaimer in the documentation and/or other materials provided
>     with the distribution.
>
>     (3)The name of the author may not be used to endorse or promote
>     products derived from this software without specific prior written
>     permission.
>
>     THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
>     IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
>     WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
>     DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT,
>     INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
>     (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
>     SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
>     HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
>     STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
>     IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
>     POSSIBILITY OF SUCH DAMAGE.

## Public-domain files

| File | Terms and attribution |
|---|---|
| `htscodecs/c_range_coder.h` | Public domain; dedicated by Eugene Shelwien, with modifications credited to James Bonfield. |
| `htscodecs/rANS_byte.h` | Public domain under Fabien Giesen's CC0 waiver. |
| `htscodecs/rANS_word.h` | Public domain under Fabien Giesen's CC0 waiver. |

> To the extent possible under law, Fabian Giesen has waived all copyright
> and related or neighboring rights to ryg_rans, as per the terms of the
> CC0 license:
>
>   https://creativecommons.org/publicdomain/zero/1.0
>
> This work is published from the United States.

The CC0 waiver text is in `LICENSE.md`; the two rANS headers carry one-line public-domain notices. `c_range_coder.h` carries its dedication and the James Bonfield modification credit. The BSD terms do not apply to the three public-domain files, and this fork's grant does not extend to them.

## Per-path inventory

| Path group | Terms | Attribution or notice |
|---|---|---|
| `htscodecs/*.c` (14 files) | BSD-3-Clause | Genome Research Limited; full notice in each file. |
| `htscodecs/*.h` (17 files, except the three above) | BSD-3-Clause | Genome Research Limited; full notice in each file. |
| `tests/*.c` (15 files), `tests/Makefile.am`, `tests/benchmark.sh`, `tests/*.test`, `tests/tok3.test` | BSD-3-Clause | Notice or copyright header in each file. |
| `tests/dat/**`, `tests/names/**` (218 files: 97 and 121) | BSD-3-Clause | Covered by `LICENSE.md`; no per-file notice. |
| `javascript/*.js` (14 files) | BSD-3-Clause | Notice in each file. |
| `javascript/Makefile`, `javascript/README.md`, `m4/*.m4` (3 files), `configure.ac`, `Makefile.am`, `htscodecs/Makefile.am` | BSD-3-Clause | Covered by `LICENSE.md`. |
| `NEWS.md`, `BENCHMARKS.md`, `MAINTAINERS.md`, `.gitattributes` | BSD-3-Clause | Covered by `LICENSE.md`. |
| `README.upstream.md` | BSD-3-Clause | Upstream's README, preserved byte for byte. |
| `LICENSE.md` | Upstream licence and its three exceptions | Licence text. |
| `.gitignore` | Mixed | Its 47 upstream entries remain unchanged; appended Zig build-output rules are fork work under `FORK-LICENSE.md`. |
| Fork-authored paths below | BSD-3-Clause | Covered by the grant in `FORK-LICENSE.md`. |

The grant covers `build.zig`, `build.zig.zon`, `build_support/`, `root.zig`, `src/htscodecs.zig`, `include/htscodecs_all.h`, `include/htscodecs_system.h`, `include/htscodecs_config.h`, `fixtures.zig`, `test/*.zig`, `examples/codec_demo.zig`, `consumer/`, `package.nix`, `flake.nix`, `devenv.nix`, `devenv.yaml`, `.envrc`, `README.md`, `README.zig.md`, `FORK-LICENSE.md`, `NOTICE.md`, `CHANGELOG.md`, `FORK-NOTES.md`, and `UPSTREAM.md`.

No upstream C source, C header, test, script, licence, or documentation file was modified. `.gitignore` is the exception: its upstream entries are unchanged, with fork build-output rules appended. `README.md` is fork-authored; `README.upstream.md` holds upstream's text and is not covered by the fork's grant.
