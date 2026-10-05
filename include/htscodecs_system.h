/*
 * htscodecs_system.h - aggregate header for system-library mode.
 *
 * Used only when the build is told to link an installed libhtscodecs
 * (`-Dsystem=true`).  Every declaration comes from the *system's*
 * headers, found on the default include path, not from this repository.
 * That is the whole point: the translated Zig interface has to describe
 * the ABI of the library that actually gets linked, so translating this
 * fork's bundled v1.6.7 headers here and linking an older installed
 * library would publish declarations for symbols the linked library may
 * not export.
 *
 * Consequences, all deliberate:
 *   * The per-ISA 32x16 entry points stay hidden unless the installed
 *     rANS_static32x16pr.h is itself compiled with HAVE_SSE4_1 / HAVE_AVX2
 *     / HAVE_AVX512 defined, because a consumer cannot know how the
 *     installed library was built.  The scalar 32x16 entry points, which
 *     every build has, are always present.
 *   * include/htscodecs_config.h is not included.  It is fork-owned and
 *     describes how *this* tree is compiled, which is not the question
 *     in this mode.
 *   * The header set is the one the installed library installs, plus
 *     rANS_static32x16pr.h where it exists.  Whether a given installed
 *     header exists at all is a property of that installation: an older
 *     release predating a declaration the facade uses fails here with a
 *     missing-header or missing-declaration error naming it.  That is
 *     the correct outcome, because the facade would otherwise call a
 *     symbol the installed library does not export.
 *   * No C keyword is redefined.  fqzcomp_qual.h's `static const int`
 *     flag bits stay internal to each translation unit, so a C program
 *     whose two translation units both include this aggregate still
 *     links.  See include/htscodecs_all.h for the longer note.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 */

#ifndef HTSCODECS_SYSTEM_H
#define HTSCODECS_SYSTEM_H

/*
 * The standard types the upstream public headers use but do not include:
 * pack.h, rle.h, tokenise_name3.h and the rest have no `#include` line at
 * all, so the aggregate has to establish them.  See the longer note in
 * include/htscodecs_all.h, which discharges the same assumption.
 */
#include <stdint.h>
#include <stddef.h>

#include <htscodecs/htscodecs.h>

#include <htscodecs/pack.h>
#include <htscodecs/rle.h>
#include <htscodecs/rANS_static.h>
#include <htscodecs/rANS_static4x16.h>
#include <htscodecs/rANS_static32x16pr.h>
#include <htscodecs/arith_dynamic.h>
#include <htscodecs/tokenise_name3.h>
#include <htscodecs/fqzcomp_qual.h>
#include <htscodecs/varint.h>
#include <htscodecs/utils.h>

#endif /* HTSCODECS_SYSTEM_H */