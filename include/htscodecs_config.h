/*
 * Build configuration macros for the Zig build of htscodecs.
 *
 * Upstream htscodecs normally discovers these with autoconf (see
 * configure.ac) and drops the result in config.h.  The Zig build has no
 * configure step, so the same decisions are expressed here as ordinary
 * preprocessor conditionals that evaluate against whichever target clang is
 * compiling for.  config.h includes this file, so the C translation units
 * and any consumer of htscodecs_all.h see exactly the same answers.
 *
 * This file is fork-owned.  See NOTICE.md.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 */

#ifndef HTSCODECS_CONFIG_H
#define HTSCODECS_CONFIG_H

/*
 * configure.ac: AC_CACHE_CHECK([for __builtin_prefetch]).
 *
 * Answered from the target's own predefined macros, so the answer is the
 * target's answer and never the build machine's.
 */
#if defined(__GNUC__) || defined(__clang__)
#  ifndef HAVE_BUILTIN_PREFETCH
#    define HAVE_BUILTIN_PREFETCH 1
#  endif
#endif

/*
 * configure.ac: AC_CHECK_DECLS([__get_cpuid_max, __cpuid_count]).
 *
 * <cpuid.h> ships with Zig's bundled compiler headers, so it resolves
 * for every x86-64 target.  Declaring the two functions therefore
 * enables the runtime CPU detection in rANS_static4x16pr.c and, with the
 * ISA macros below, the per-ISA 32x16 kernels.
 *
 * Without these the build still compiles: rANS_static4x16pr.c takes
 * its #else branch and hard-codes the scalar function pointers, so the
 * kernels would be built and never called.  That is a silent downgrade,
 * not an error, which is why the macros are here.
 */
#if defined(__x86_64__)
#  ifndef HAVE_DECL___CPUID_COUNT
#    define HAVE_DECL___CPUID_COUNT 1
#  endif
#  ifndef HAVE_DECL___GET_CPUID_MAX
#    define HAVE_DECL___GET_CPUID_MAX 1
#  endif
#endif
/*
 * ISA macros for the 32x16 per-kernel entry points.
 *
 * INVARIANT.  These are true exactly when the target is x86-64, and
 * build.zig adds the sse4, avx2 and avx512 kernel objects exactly when
 * the target's cpu arch is x86_64.  Both sides key off the target, so
 * they cannot disagree; but the two are separate pieces of code and a
 * kernel added to one has to be added to the other in the same change,
 * or the archive and its translated header describe different
 * libraries.
 *
 * Each kernel is compiled as its own object with its own -m flags,
 * exactly as htscodecs/Makefile.am does with libtool convenience
 * libraries, so the scalar object never picks up AVX code.  The macros
 * below select the *declarations*; which of them a given machine may
 * execute is decided at run time by the cpuid detection above, so a
 * binary built here still runs on a CPU without AVX2.
 *
 * The Arm Neon entry points need nothing here: upstream guards them on
 * __ARM_NEON and __aarch64_, which the target's predefined macros
 * already answer.
 */
#if defined(__x86_64__)
#  ifndef HAVE_SSE4_1
#    define HAVE_SSE4_1 1
#  endif
#  ifndef HAVE_SSSE3
#    define HAVE_SSSE3 1
#  endif
#  ifndef HAVE_POPCNT
#    define HAVE_POPCNT 1
#  endif
#  ifndef HAVE_AVX2
#    define HAVE_AVX2 1
#  endif
#  ifndef HAVE_AVX512
#    define HAVE_AVX512 1
#  endif
#endif

/*
 * wasi-libc declares the pthread entry points but does not implement
 * pthread_once/pthread_key_create, so the thread-local scratch pools in
 * utils.c and rANS_static4x16pr.c cannot link there.  Upstream already
 * supports a NO_THREADS build that falls back to plain calloc/free; we
 * select it for wasm32 rather than pretending threads exist.
 */
#if defined(__wasi__)
#  ifndef NO_THREADS
#    define NO_THREADS 1
#  endif
#endif

/*
 * bzip2 support is opt-in at the Zig level (-Dbz2=true), mirroring
 * upstream's --disable-bz2 default of "off unless libbz2 was found".
 * With this macro unset, arith_dynamic's external-codec method
 * (X_EXT, bit 0x04) cannot be encoded or decoded: arith_compress
 * prints a diagnostic and returns NULL, arith_uncompress fails the
 * same way.  Streams that were produced with bzip2 are therefore
 * undecodable in the default build.
 *
 * HTSCODECS_WITH_BZ2 is a fork-owned name, not an autoconf probe.
 * build.zig passes it to the C compilation and to the translate-c
 * invocation alike, so this file answers identically for the archive
 * and for its translated interface.  No installed public header is
 * guarded by HAVE_LIBBZ2 at present, so the answer does not change the
 * translated declaration set today; it is one decision reaching both
 * consumers rather than two that can drift.
 */
#ifdef HTSCODECS_WITH_BZ2
#  ifndef HAVE_LIBBZ2
#    define HAVE_LIBBZ2 1
#  endif
#endif

#endif /* HTSCODECS_CONFIG_H */
