/*
 * htscodecs_all.h - aggregate public C header for the Zig build.
 *
 * Upstream ships its public headers under htscodecs/ and expects a caller
 * to include the one it needs.  The Zig package publishes a single
 * aggregate so that b.addTranslateC has one translation unit to chew on
 * and so that consumers of the installed package get the complete C
 * surface in one include.  It adds no declaration of its own: every
 * declaration below is upstream's, included verbatim.
 *
 * WHAT "PUBLIC" MEANS HERE
 * -----------------------
 * The selection is the nine headers upstream itself installs, taken from
 * its top-level `Makefile.am` `nobase_include_HEADERS`
 * (`arith_dynamic.h`, `fqzcomp_qual.h`, `rANS_static.h`,
 * `rANS_static4x16.h`, `tokenise_name3.h`, `pack.h`, `rle.h`,
 * `varint.h`, `htscodecs.h`), plus the two headers this fork must also
 * expose because it compiles symbols out of them and installs them
 * beside the rest:
 *
 *   rANS_static32x16pr.h
 *       Upstream does not install it, but the per-ISA 32x16 entry points
 *       are the reason the three x86 kernels and the Neon kernel are
 *       built at all.  A package that ships the objects and hides the
 *       declarations would make them unreachable.
 *
 *   utils.h
 *       `htscodecs_tls_alloc`, `htscodecs_tls_calloc` and
 *       `htscodecs_tls_free` are ordinary exported functions compiled
 *       from `utils.c`.  Without this header the translated interface
 *       would not declare a symbol the archive really exports.
 *
 * The two extra headers come last on purpose.  `varint.h` defines
 * `BIG_END`, `var_size_u32` and `var_size_s32`; `utils.h` defines
 * `MAGIC`, `likely` and `unlikely`.  These are ordinary header macros
 * and an aggregate header unavoidably leaks them into the includer, so
 * they are included after every API header rather than before one.
 *
 * WHY NOTHING HERE REDEFINES A C KEYWORD
 * -------------------------------------
 * `fqzcomp_qual.h` declares its `GFLAG_*` and `PFLAG_*` bits as
 * `static const int` file-scope constants, and it pulls in <stdint.h>
 * while doing so.  Those constants must keep internal linkage: they are
 * definitions, not declarations, so two translation units of one program
 * that both include this aggregate would each define them at external
 * linkage and the link would fail with duplicate symbols.  Rewriting the
 * `static` keyword to make them look translation-friendly achieves the
 * opposite of what it intends, and it also puts a libc header inside the
 * same window.  So the keyword is left alone, the constants stay
 * internal to each translation unit, and whether `b.addTranslateC`
 * chooses to expose them is a question for the tool rather than something
 * this header guesses at.
 *
 * The C linkage upstream declares with `extern "C"` is likewise
 * untouched, so a C++ caller of this aggregate gets the same symbols a
 * C caller does.
 *
 * Includes are written relative to this file so that they resolve
 * without any -I flag from either layout:
 *
 *   source tree   include/htscodecs_all.h      -> ../htscodecs/*.h
 *   installed     include/htscodecs/htscodecs_all.h -> ../htscodecs/*.h
 *
 * `htscodecs_config.h` sits beside this file in both layouts.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 */

#ifndef HTSCODECS_ALL_H
#define HTSCODECS_ALL_H

/*
 * Feature macros first.  rANS_static32x16pr.h hides the per-ISA 32x16
 * entry points behind HAVE_SSE4_1 / HAVE_AVX2 / HAVE_AVX512, and the
 * header expresses every one of its own conditions against the target
 * clang is compiling for, so the translated Zig interface describes the
 * archive that this build produced for this target.
 */
#include "htscodecs_config.h"

/*
 * The standard types the upstream public headers use but do not include.
 * Not one of pack.h, htscodecs.h, rle.h, arith_dynamic.h or
 * tokenise_name3.h has an `#include` line at all: they are written to be
 * included after a translation unit has already established `uint8_t`,
 * `int64_t` and the rest, which upstream's own .c files do by including
 * <stdint.h> before "config.h".  An aggregate header is exactly the
 * place where that assumption has to be discharged, or a consumer that
 * includes only this file gets "type specifier missing" on the first
 * `uint8_t *` in pack.h.  These are libc headers, not declarations, so
 * including them here adds nothing to the public surface.
 */
#include <stdint.h>
#include <stddef.h>
#include "../htscodecs/htscodecs.h"

#include "../htscodecs/pack.h"
#include "../htscodecs/rle.h"
#include "../htscodecs/rANS_static.h"
#include "../htscodecs/rANS_static4x16.h"
#include "../htscodecs/rANS_static32x16pr.h"
#include "../htscodecs/arith_dynamic.h"
#include "../htscodecs/tokenise_name3.h"

/*
 * fqzcomp_qual.h keeps its `static const int` flag bits as upstream wrote
 * them; see the note above about internal linkage.
 */
#include "../htscodecs/fqzcomp_qual.h"

/* The two headers this fork installs and compiles symbols from. */
#include "../htscodecs/varint.h"
#include "../htscodecs/utils.h"

#endif /* HTSCODECS_ALL_H */