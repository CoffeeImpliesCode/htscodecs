// SPDX-License-Identifier: BSD-3-Clause
//
//! Builds the target-specific runtime-loaded module graph.
//! Do not link the native archive into a module that imports this dispatch.

const std = @import("std");

/// Must match the sync prefix used in `runtime/sync.c` and `runtime/library.zig`.
/// Give each independent loader instance its own prefix and sync files.
const sync_prefix = "htscodecs_rt";

/// Keep C-library externs emitted by `translate-c` direct for supported targets.
/// Use exact names, including optimized aliases; no htscodecs API name belongs here.
const libc_noise =
    \\memcpy,memmove,memccpy,memset,memcmp,__memcmpeq,memchr,strcpy,strncpy,strcat,strncat,strcmp,
    \\strncmp,strcoll,strxfrm,strcoll_l,strxfrm_l,strdup,strndup,strchr,strrchr,strchrnul,strcspn,
    \\strspn,strpbrk,strstr,strtok,__strtok_r,strtok_r,strcasestr,memmem,__mempcpy,mempcpy,strlen,
    \\strnlen,strerror,strerror_r,strerror_l,bcmp,bcopy,bzero,index,rindex,ffs,ffsl,ffsll,
    \\strcasecmp,strncasecmp,strcasecmp_l,strncasecmp_l,explicit_bzero,strsep,strsignal,__stpcpy,
    \\stpcpy,__stpncpy,stpncpy,strlcpy,strlcat,__ctype_get_mb_cur_max,atof,atoi,atol,atoll,strtod,
    \\strtof,strtold,strtol,strtoul,strtoq,strtouq,strtoll,strtoull,l64a,a64l,select,pselect,
    \\random,srandom,initstate,setstate,random_r,srandom_r,initstate_r,setstate_r,rand,srand,
    \\rand_r,drand48,erand48,lrand48,nrand48,mrand48,jrand48,srand48,seed48,lcong48,drand48_r,
    \\erand48_r,lrand48_r,nrand48_r,mrand48_r,jrand48_r,srand48_r,seed48_r,lcong48_r,arc4random,
    \\arc4random_buf,arc4random_uniform,malloc,calloc,realloc,free,reallocarray,alloca,valloc,
    \\posix_memalign,aligned_alloc,abort,atexit,at_quick_exit,on_exit,exit,quick_exit,_Exit,
    \\getenv,putenv,setenv,unsetenv,clearenv,mktemp,mkstemp,mkstemps,mkdtemp,system,realpath,
    \\bsearch,qsort,abs,labs,llabs,div,ldiv,lldiv,ecvt,fcvt,gcvt,qecvt,qfcvt,qgcvt,ecvt_r,fcvt_r,
    \\qecvt_r,qfcvt_r,mblen,mbtowc,wctomb,mbstowcs,wcstombs,rpmatch,getsubopt,getloadavg,
    \\__fpclassify,__signbit,__isinf,__finite,__isnan,__iseqsig,__issignaling,acos,__acos,asin,
    \\__asin,atan,__atan,atan2,__atan2,cos,__cos,sin,__sin,tan,__tan,cosh,__cosh,sinh,__sinh,tanh,
    \\__tanh,acosh,__acosh,asinh,__asinh,atanh,__atanh,exp,__exp,frexp,__frexp,ldexp,__ldexp,log,
    \\__log,log10,__log10,modf,__modf,expm1,__expm1,log1p,__log1p,logb,__logb,exp2,__exp2,log2,
    \\__log2,pow,__pow,sqrt,__sqrt,hypot,__hypot,cbrt,__cbrt,ceil,__ceil,fabs,__fabs,floor,
    \\__floor,fmod,__fmod,isinf,finite,drem,__drem,significand,__significand,copysign,__copysign,
    \\nan,__nan,isnan,j0,__j0,j1,__j1,jn,__jn,y0,__y0,y1,__y1,yn,__yn,erf,__erf,erfc,__erfc,
    \\lgamma,__lgamma,tgamma,__tgamma,gamma,__gamma,lgamma_r,__lgamma_r,rint,__rint,nextafter,
    \\__nextafter,nexttoward,__nexttoward,remainder,__remainder,scalbn,__scalbn,ilogb,__ilogb,
    \\scalbln,__scalbln,nearbyint,__nearbyint,round,__round,trunc,__trunc,remquo,__remquo,lrint,
    \\__lrint,llrint,__llrint,lround,__lround,llround,__llround,fdim,__fdim,fmax,__fmax,fmin,
    \\__fmin,fma,__fma,scalb,__scalb,__fpclassifyf,__signbitf,__isinff,__finitef,__isnanf,
    \\__iseqsigf,__issignalingf,acosf,__acosf,asinf,__asinf,atanf,__atanf,atan2f,__atan2f,cosf,
    \\__cosf,sinf,__sinf,tanf,__tanf,coshf,__coshf,sinhf,__sinhf,tanhf,__tanhf,acoshf,__acoshf,
    \\asinhf,__asinhf,atanhf,__atanhf,expf,__expf,frexpf,__frexpf,ldexpf,__ldexpf,logf,__logf,
    \\log10f,__log10f,modff,__modff,expm1f,__expm1f,log1pf,__log1pf,logbf,__logbf,exp2f,__exp2f,
    \\log2f,__log2f,powf,__powf,sqrtf,__sqrtf,hypotf,__hypotf,cbrtf,__cbrtf,ceilf,__ceilf,fabsf,
    \\__fabsf,floorf,__floorf,fmodf,__fmodf,isinff,finitef,dremf,__dremf,significandf,
    \\__significandf,copysignf,__copysignf,nanf,__nanf,isnanf,j0f,__j0f,j1f,__j1f,jnf,__jnf,y0f,
    \\__y0f,y1f,__y1f,ynf,__ynf,erff,__erff,erfcf,__erfcf,lgammaf,__lgammaf,tgammaf,__tgammaf,
    \\gammaf,__gammaf,lgammaf_r,__lgammaf_r,rintf,__rintf,nextafterf,__nextafterf,nexttowardf,
    \\__nexttowardf,remainderf,__remainderf,scalbnf,__scalbnf,ilogbf,__ilogbf,scalblnf,__scalblnf,
    \\nearbyintf,__nearbyintf,roundf,__roundf,truncf,__truncf,remquof,__remquof,lrintf,__lrintf,
    \\llrintf,__llrintf,lroundf,__lroundf,llroundf,__llroundf,fdimf,__fdimf,fmaxf,__fmaxf,fminf,
    \\__fminf,fmaf,__fmaf,scalbf,__scalbf,__fpclassifyl,__signbitl,__isinfl,__finitel,__isnanl,
    \\__iseqsigl,__issignalingl,acosl,__acosl,asinl,__asinl,atanl,__atanl,atan2l,__atan2l,cosl,
    \\__cosl,sinl,__sinl,tanl,__tanl,coshl,__coshl,sinhl,__sinhl,tanhl,__tanhl,acoshl,__acoshl,
    \\asinhl,__asinhl,atanhl,__atanhl,expl,__expl,frexpl,__frexpl,ldexpl,__ldexpl,logl,__logl,
    \\log10l,__log10l,modfl,__modfl,expm1l,__expm1l,log1pl,__log1pl,logbl,__logbl,exp2l,__exp2l,
    \\log2l,__log2l,powl,__powl,sqrtl,__sqrtl,hypotl,__hypotl,cbrtl,__cbrtl,ceill,__ceill,fabsl,
    \\__fabsl,floorl,__floorl,fmodl,__fmodl,isinfl,finitel,dreml,__dreml,significandl,
    \\__significandl,copysignl,__copysignl,nanl,__nanl,isnanl,j0l,__j0l,j1l,__j1l,jnl,__jnl,y0l,
    \\__y0l,y1l,__y1l,ynl,__ynl,erfl,__erfl,erfcl,__erfcl,lgammal,__lgammal,tgammal,__tgammal,
    \\gammal,__gammal,lgammal_r,__lgammal_r,rintl,__rintl,nextafterl,__nextafterl,nexttowardl,
    \\__nexttowardl,remainderl,__remainderl,scalbnl,__scalbnl,ilogbl,__ilogbl,scalblnl,__scalblnl,
    \\nearbyintl,__nearbyintl,roundl,__roundl,truncl,__truncl,remquol,__remquol,lrintl,__lrintl,
    \\llrintl,__llrintl,lroundl,__lroundl,llroundl,__llroundl,fdiml,__fdiml,fmaxl,__fmaxl,fminl,
    \\__fminl,fmal,__fmal,scalbl,__scalbl,__fpclassifyf128,__signbitf128,__isinff128,__finitef128,
    \\__isnanf128,__iseqsigf128,__issignalingf128,signgam,
    \\_byteswap_ulong,_byteswap_ushort,_cabs,_chgsign,_chgsignf,_chgsignl,_copysign,_copysignf,_dupenv_s,_ecvt,_ecvt_s,
    \\_errno,_exit,_expand,_fcvt,_fcvt_s,_finite,_finitef,_fpclass,_fpclassf,_fullpath,_gcvt,_gcvt_s,_get_amblksiz,
    \\_get_doserrno,_get_errno,_get_fmode,_get_heap_handle,_get_invalid_parameter_handler,_get_osplatform,_get_osver,
    \\_get_pgmptr,_get_purecall_handler,_get_sbh_threshold,_get_winmajor,_get_winminor,_get_winver,_get_wpgmptr,_heapadd,
    \\_heapchk,_heapmin,_heapset,_heapused,_heapwalk,_hypot,_i64toa,_i64toa_s,_i64tow,_i64tow_s,_isnan,_isnanf,_itoa,
    \\_itoa_s,_itow,_itow_s,_j0,_j1,_jn,_logb,_logbf,_lrotl,_lrotr,_ltoa,_ltoa_s,_ltow,_ltow_s,_makepath,_makepath_s,
    \\_matherr,_mblen_l,_mbstowcs_l,_mbstowcs_s_l,_mbstrlen,_mbstrlen_l,_mbstrnlen,_mbstrnlen_l,_mbtowc_l,_memccpy,
    \\_memicmp,_memicmp_l,_msize,_nextafter,_nextafterf,_onexit,_putenv,_putenv_s,_recalloc,_resetstkoflw,_rotl,_rotl64,
    \\_rotr,_rotr64,_scalb,_searchenv,_searchenv_s,_set_abort_behavior,_set_amblksiz,_set_doserrno,_set_errno,
    \\_set_error_mode,_set_fmode,_set_invalid_parameter_handler,_set_malloc_crt_max_wait,_set_purecall_handler,
    \\_set_sbh_threshold,_seterrormode,_sleep,_splitpath,_splitpath_s,_strcmpi,_strcoll_l,_strdup,_strerror,_strerror_s,
    \\_stricmp,_stricmp_l,_stricoll,_stricoll_l,_strlwr,_strlwr_s,_strlwr_s_l,_strncat_s_l,_strncoll,_strncoll_l,
    \\_strncpy_s_l,_strnicmp,_strnicmp_l,_strnicoll,_strnicoll_l,_strnset,_strnset_l,_strnset_s,_strrev,_strset,_strset_l,
    \\_strset_s,_strtod_l,_strtof_l,_strtoi64,_strtoi64_l,_strtok_s_l,_strtol_l,_strtoui64,_strtoui64_l,_strtoul_l,_strupr,
    \\_strupr_l,_strupr_s,_strupr_s_l,_strxfrm_l,_swab,_ui64toa,_ui64toa_s,_ui64tow,_ui64tow_s,_ultoa,_ultoa_s,_ultow,
    \\_ultow_s,_wcscoll_l,_wcsdup,_wcserror,_wcserror_s,_wcsicmp,_wcsicmp_l,_wcsicoll,_wcsicoll_l,_wcslwr,_wcslwr_l,
    \\_wcslwr_s,_wcslwr_s_l,_wcsncat_s_l,_wcsncoll,_wcsncoll_l,_wcsncpy_l,_wcsncpy_s_l,_wcsnicmp,_wcsnicmp_l,_wcsnicoll,
    \\_wcsnicoll_l,_wcsnset,_wcsnset_s,_wcsnset_s_l,_wcsrev,_wcsset,_wcsset_s,_wcsset_s_l,_wcstod_l,_wcstof_l,_wcstoi64,
    \\_wcstoi64_l,_wcstok,_wcstok_s_l,_wcstol_l,_wcstombs_l,_wcstombs_s_l,_wcstoui64,_wcstoui64_l,_wcstoul_l,_wcsupr,
    \\_wcsupr_l,_wcsupr_s,_wcsupr_s_l,_wcsxfrm_l,_wctomb_l,_wctomb_s_l,_wdupenv_s,_wfullpath,_wgetenv,_wgetenv_s,
    \\_wmakepath,_wmakepath_s,_wperror,_wputenv,_wputenv_s,_wsearchenv,_wsearchenv_s,_wsplitpath,_wsplitpath_s,_wsystem,
    \\_wtof,_wtof_l,_wtoi,_wtoi64,_wtoi64_l,_wtoi_l,_wtol,_wtol_l,_y0,_y1,_yn,abort2,abort_handler_s,arc4random_addrandom,
    \\arc4random_stir,bsearch_s,calloc_conceal,cgetcap,cgetclose,cgetent,cgetfirst,cgetmatch,cgetnext,cgetnum,cgetset,
    \\cgetstr,cgetusedb,cgetustr,chgsign,cospi,cospif,cospil,daemon,daemonfd,devname,devname_r,fdevname,fdevname_r,fls,
    \\flsl,flsll,fpclass,freezero,ftruncate,gamma_r,gammaf_r,getbsize,getenv_r,getenv_s,getiopolicy_np,getpriority,
    \\getprogname,getrlimit,getrusage,grantpt,heapsort,ignore_handler_s,itoa,l64a_r,lcong48_deterministic,lseek,ltoa,
    \\malloc_conceal,malloc_conf,malloc_message,malloc_type_aligned_alloc,malloc_type_calloc,malloc_type_free,
    \\malloc_type_malloc,malloc_type_posix_memalign,malloc_type_realloc,malloc_type_valloc,malloc_type_zone_calloc,
    \\malloc_type_zone_free,malloc_type_zone_malloc,malloc_type_zone_memalign,malloc_type_zone_realloc,
    \\malloc_type_zone_valloc,mbstowcs_s,memalign,memcpy_s,memicmp,memmove_s,memrchr,memset_explicit,memset_pattern16,
    \\memset_pattern4,memset_pattern8,memset_s,mergesort,mkdtemps,mkostemp,mkostemps,mkostempsat,onexit,perror,
    \\posix_openpt,psort,psort_r,ptsname,ptsname_r,qabs,qdiv,qsort_r,qsort_s,radixsort,reallocf,recallocarray,rinttol,
    \\roundtol,secure_getenv,seed48_deterministic,set_constraint_handler_s,setiopolicy_np,setkey,setpriority,setproctitle,
    \\setprogname,setrlimit,signal,sincos,sincosf,sincosl,sinpi,sinpif,sinpil,sradixsort,srand48_deterministic,
    \\srand_deterministic,sranddev,srandom_deterministic,srandomdev,strcat_s,strcmpi,strcpy_s,strerror_s,stricmp,strlwr,
    \\strlwr_l,strmode,strncat_s,strncpy_s,strnicmp,strnset,strnstr,strrev,strset,strsignal_r,strtok_s,strtonum,strupr,
    \\strverscmp,suboptarg,swab,tanpi,tanpif,tanpil,timingsafe_bcmp,timingsafe_memcmp,truncate,ttyslot,ultoa,unlockpt,wait,
    \\wait3,wait4,waitid,waitpid,wcscat,wcscat_s,wcschr,wcscmp,wcscoll,wcscpy,wcscpy_s,wcscspn,wcsdup,wcsicmp,wcsicoll,
    \\wcslen,wcslwr,wcsncat,wcsncat_s,wcsncmp,wcsncpy,wcsncpy_s,wcsnicmp,wcsnlen,wcsnset,wcspbrk,wcsrchr,wcsrev,wcsset,
    \\wcsspn,wcsstr,wcstod,wcstof,wcstok,wcstok_s,wcstol,wcstold,wcstombs_s,wcstoul,wcsupr,wcsxfrm,wctomb_s,
    \\_OSSwapInt32,_OSSwapInt64,___mb_cur_max,___mb_cur_max_func,__ceilf16,__copysignf16,__cospi,__cospif,__doserrno,
    \\__exp10,__exp10f,__fabsf16,__floorf16,__fmaf16,__fmaxf16,__fminf16,__fpclassifyd,__hypotf16,__imp__HUGE,__inf,__inff,
    \\__infinity,__infl,__inline_isfinited,__inline_isfinitel,__inline_isinfd,__inline_isinfl,__inline_isnormall,
    \\__isfinite,__isfinitef,__isfinitel,__isnormal,__isnormalf,__isnormall,__math_errhandling,__mb_cur_max,
    \\__mingw_aligned_free,__mingw_aligned_malloc,__mingw_aligned_msize,__mingw_aligned_offset_malloc,
    \\__mingw_aligned_offset_realloc,__mingw_aligned_realloc,__mingw_get_crt_info,__mingw_raise_matherr,
    \\__mingw_setusermatherr,__mingw_strtod,__mingw_strtof,__mingw_strtold,__mingw_wcstod,__mingw_wcstof,__mingw_wcstold,
    \\__nextafterf16,__p___argc,__p___argv,__p___wargv,__p__amblksiz,__p__environ,__p__fmode,__p__osplatform,__p__osver,
    \\__p__pgmptr,__p__wenviron,__p__winmajor,__p__winminor,__p__winver,__p__wpgmptr,__prefetch,__qsort_r_compat,__rintf16,
    \\__roundf16,__setusermatherr,__sincos_stret,__sincosf_stret,__sincospi_stret,__sincospif_stret,__sinpi,__sinpif,
    \\__sqrtf16,__strtod,__sys_errlist,__sys_nerr,__tanpi,__tanpif,__truncf16,__wcserror,__wcserror_s,_aligned_free,
    \\_aligned_malloc,_aligned_msize,_aligned_offset_malloc,_aligned_offset_realloc,_aligned_offset_recalloc,
    \\_aligned_realloc,_aligned_recalloc,_atodbl,_atodbl_l,_atof_l,_atoflt,_atoflt_l,_atoi64,_atoi64_l,_atoi_l,_atol_l,
    \\_atoldbl,_atoldbl_l,_beep,_byteswap_uint64,
    \\__explicit_bzero_chk,__fdelt_chk,__fdelt_warn,__mbstowcs_alias,__mbstowcs_chk,__mbstowcs_chk_warn,
    \\__mbstowcs_nulldst,__ptsname_r_alias,__ptsname_r_chk,__ptsname_r_chk_warn,__realpath_alias,__realpath_chk,
    \\__realpath_chk_warn,__strlcat_alias,__strlcat_chk,__strlcpy_alias,__strlcpy_chk,__wcstombs_alias,
    \\__wcstombs_chk,__wcstombs_chk_warn,__wctomb_alias,__wctomb_chk
;

/// The declared SSE4 compressor has no implementation (`rANS_static32x16pr_sse4.c`).
/// If the provider omits it, its optional wrapper panics by name when called.
const provider_optional = "rans_compress_O0_32x16_sse4";

/// No provider symbols are excluded; `hts_unpack_` lacks a header declaration (`pack.c`).
const provider_excluded = "";

/// Creates the linked-build loader core so `LoadSource` and `LoadError` retain their types.
/// Runtime modules create the core through the dispatch instead.
pub fn createCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("runtime/loader.zig"),
        .target = target,
        .optimize = optimize,
        // Unix uses `dlopen` from libc; linked builds do not compile this module.
        .link_libc = true,
    });
}

/// Builds the runtime-loaded `c` module from this target's translation output.
/// The generated dispatch must match that target and configuration.
pub fn createModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const core = createCoreModule(b, target, optimize);

    const library = b.createModule(.{
        .root_source_file = b.path("runtime/library.zig"),
        .target = target,
        .optimize = optimize,
    });
    library.addImport("rt", core);

    return createDispatchModule(b, translate, target, optimize, core, library);
}

const GeneratedSources = struct {
    native: std.Build.LazyPath,
    dispatch: std.Build.LazyPath,
};

fn createDispatchModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
    library: *std.Build.Module,
) *std.Build.Module {
    const sources = generateDispatch(b, translate, target);

    const dispatch = b.createModule(.{
        .root_source_file = sources.dispatch,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dispatch.addImport("rt", core);
    dispatch.addImport("library", library);

    // Re-export the patched translation to preserve nominal types and route nested members.
    const native = b.createModule(.{
        .root_source_file = sources.native,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native.addImport("c_routed", dispatch);
    dispatch.addImport("c_native", native);
    dispatch.addCSourceFiles(.{
        .files = &.{"runtime/sync.c"},
        .flags = &.{b.fmt("-DRT_SYNC_PREFIX={s}", .{sync_prefix})},
        .language = .c,
    });
    return dispatch;
}

/// Runs the host generator on this target's translation output.
/// Each target and configuration gets a matching dispatch.
fn generateDispatch(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
) GeneratedSources {
    const generator = b.addExecutable(.{
        .name = b.fmt("htscodecs-runtime-generate-{s}", .{
            target.result.zigTriple(b.allocator) catch @panic("unspellable target"),
        }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/generate.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run = b.addRunArtifact(generator);
    run.addArg("--library");
    run.addArg("htscodecs");
    run.addArg("--translate");
    run.addFileArg(translate.getOutput());
    if (libc_noise.len != 0) {
        run.addArg("--noise");
        run.addArg(libc_noise);
    }
    if (provider_optional.len != 0) {
        run.addArg("--optional");
        run.addArg(provider_optional);
    }
    if (provider_excluded.len != 0) {
        run.addArg("--exclude");
        run.addArg(provider_excluded);
    }
    run.addArg("--native-output");
    const native_source = run.addOutputFileArg("native.zig");
    run.addArg("--output");
    const dispatch_source = run.addOutputFileArg("dispatch.zig");
    return .{ .native = native_source, .dispatch = dispatch_source };
}
