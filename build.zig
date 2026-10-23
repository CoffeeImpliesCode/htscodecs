//! SPDX-License-Identifier: BSD-3-Clause

const std = @import("std");

const graph = @import("runtime/graph.zig");

const upstream_version = "1.6.7";
const upstream_commit = "b9fc194f772e45bb0a1f44b08cbf8697a1384bae";

/// Scalar units follow upstream `Makefile.am`; ISA kernels compile separately.
const scalar_sources = [_][]const u8{
    "pack.c",
    "rle.c",
    "fqzcomp_qual.c",
    "rANS_static.c",
    "rANS_static4x16pr.c",
    "rANS_static32x16pr.c",
    "tokenise_name3.c",
    "arith_dynamic.c",
    "htscodecs.c",
    "utils.c",
};

/// ISA objects follow their source guards; `exports` lists definitions, not header declarations.
/// AArch64 Neon covers both `.aarch64` and `.aarch64_be`.
/// Upstream declares the SSE4 O0 encoder, but compiles it out.
const SimdKernel = struct {
    name: []const u8,
    archs: []const std.Target.Cpu.Arch,
    source: []const u8,
    features: []const std.Target.x86.Feature = &.{},
    exports: []const []const u8 = &.{},
};

const simd_kernels = [_]SimdKernel{
    .{
        .name = "sse4",
        .archs = &.{.x86_64},
        .source = "rANS_static32x16pr_sse4.c",
        .features = &.{ .sse4_1, .ssse3, .popcnt },
        .exports = &.{
            "rans_uncompress_O0_32x16_sse4",
            "rans_uncompress_O1_32x16_sse4",
        },
    },
    .{
        .name = "avx2",
        .archs = &.{.x86_64},
        .source = "rANS_static32x16pr_avx2.c",
        .features = &.{ .avx2, .popcnt },
        .exports = &.{
            "rans_compress_O0_32x16_avx2",
            "rans_uncompress_O0_32x16_avx2",
            "rans_compress_O1_32x16_avx2",
            "rans_uncompress_O1_32x16_avx2",
        },
    },
    .{
        .name = "avx512",
        .archs = &.{.x86_64},
        .source = "rANS_static32x16pr_avx512.c",
        .features = &.{ .avx512f, .avx2, .popcnt },
        .exports = &.{
            "rans_compress_O0_32x16_avx512",
            "rans_uncompress_O0_32x16_avx512",
            "rans_compress_O1_32x16_avx512",
            "rans_uncompress_O1_32x16_avx512",
        },
    },
    .{
        .name = "neon",
        .archs = &.{ .aarch64, .aarch64_be },
        .source = "rANS_static32x16pr_neon.c",
        .exports = &.{
            "rans_compress_O0_32x16_neon",
            "rans_uncompress_O0_32x16_neon",
            "rans_compress_O1_32x16_neon",
            "rans_uncompress_O1_32x16_neon",
        },
    },
};

/// Shared by object selection and Windows exports so both use the same target predicate.
fn targetBuildsKernel(target: std.Build.ResolvedTarget, kernel: SimdKernel) bool {
    for (kernel.archs) |arch| {
        if (target.result.cpu.arch == arch) return true;
    }
    return false;
}

/// Upstream libtool ABI: current=3, age=1, revision=12 (not release 1.6.7).
const libtool_abi = std.SemanticVersion{ .major = 3 - 1, .minor = 0, .patch = 12 };

/// Definitions exported by Windows DLLs; other formats keep upstream's export defaults.
const public_symbols = [_][]const u8{
    "arith_compress",
    "arith_compress_bound",
    "arith_compress_to",
    "arith_uncompress",
    "arith_uncompress_to",
    "fqz_compress",
    "fqz_decompress",
    "fqz_qual_stats",
    "hts_pack",
    "hts_rle_decode",
    "hts_rle_encode",
    "hts_unpack",
    "hts_unpack_meta",
    "htscodecs_tls_alloc",
    "htscodecs_tls_calloc",
    "htscodecs_tls_free",
    "htscodecs_version",
    "rans_compress",
    "rans_compress_4x16",
    "rans_compress_O0_32x16",
    "rans_compress_O1_32x16",
    "rans_compress_bound_4x16",
    "rans_compress_to_4x16",
    "rans_set_cpu",
    "rans_uncompress",
    "rans_uncompress_4x16",
    "rans_uncompress_O0_32x16",
    "rans_uncompress_O1_32x16",
    "rans_uncompress_to_4x16",
    "tok3_decode_names",
    "tok3_encode_names",
};

const c_flags = [_][]const u8{"-std=gnu11"};

/// Install upstream API headers beside the fork's aggregate and configuration headers.
const upstream_headers = [_][]const u8{
    "arith_dynamic.h",
    "fqzcomp_qual.h",
    "htscodecs.h",
    "pack.h",
    "rANS_static.h",
    "rANS_static4x16.h",
    "rANS_static32x16pr.h",
    "rle.h",
    "tokenise_name3.h",
    "utils.h",
    "varint.h",
};

const fork_headers = [_][]const u8{
    "htscodecs_all.h",
    "htscodecs_config.h",
};

/// Required licence and provenance records.
const required_records = [_][]const u8{
    "LICENSE.md",
    "NOTICE.md",
    "UPSTREAM.md",
    "CHANGELOG.md",
    "README.zig.md",
    "FORK-LICENSE.md",
};

/// Records installed under `share/licenses/htscodecs/`.
const installed_licence_records = [_][]const u8{
    "LICENSE.md",
    "NOTICE.md",
    "UPSTREAM.md",
    "FORK-LICENSE.md",
};

/// Keep the upstream README as provenance, not installed docs; it describes autotools.
const installed_docs = [_][]const u8{
    "README.md",
    "README.zig.md",
    "CHANGELOG.md",
    "FORK-NOTES.md",
};

/// Default compile-only cross-target matrix.
const matrix = [_]struct {
    name: []const u8,
    query: std.Target.Query,
}{
    .{
        .name = "x86_64-linux-gnu",
        .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    },
    .{
        .name = "aarch64-linux-gnu",
        .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    },
    .{
        // Zig's default `.none` ABI is ordinary macOS, not a libc-less target.
        .name = "aarch64-macos-none",
        .query = .{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none },
    },
    .{
        .name = "x86_64-windows-gnu",
        .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    },
    .{
        .name = "riscv64-linux-gnu",
        .query = .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
    },
    .{
        .name = "wasm32-wasi",
        .query = .{ .cpu_arch = .wasm32, .os_tag = .wasi },
    },
};

/// Additional targets accepted by `-Dcheck-targets`.
const extra_matrix = [_]struct { name: []const u8, query: std.Target.Query }{
    .{ .name = "aarch64-macos", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    .{ .name = "x86_64-macos", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
    .{ .name = "aarch64-windows-gnu", .query = .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu } },
};

/// Behavioural test files.
const test_files = [_][]const u8{
    "test/fixture_decode_test.zig",
    "test/roundtrip_test.zig",
    "test/malformed_test.zig",
    "test/facade_contract_test.zig",
};

const example_file = "examples/codec_demo.zig";

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const bz2 = b.option(
        bool,
        "bz2",
        "Compile the arithmetic coder's bzip2 external method (HAVE_LIBBZ2). " ++
            "Requires libbz2 development files for the target.  Off by default, " ++
            "which matches upstream's behaviour when libbz2 is not found.",
    ) orelse false;
    const linkage = b.option(
        std.lang.LinkMode,
        "linkage",
        "Link the C artifact as a static archive (the default, and this " ++
            "SDK's existing policy) or as a real shared library.  Ignored " ++
            "under -fsys=htscodecs, where the installed library's linkage " ++
            "is not this build's to choose.",
    ) orelse .static;
    const runtime = b.option(
        bool,
        "runtime",
        "Resolve the native symbols at run time instead of linking them: the " ++
            "facade's `c` becomes the dispatch runtime/graph.zig generates " ++
            "from this very translation step, and no native library is " ++
            "linked into it.  Orthogonal to -Dlinkage; the C artifact is " ++
            "still built and installed in both configurations, because in " ++
            "this one it is the provider the dispatch binds to.",
    ) orelse false;
    const use_system = b.systemIntegrationOption("htscodecs", .{
        .default = false,
    });

    // System mode links its installed library and headers; it cannot generate a runtime dispatch.
    if (use_system and runtime) {
        std.debug.panic(
            "-fsys=htscodecs and -Druntime=true cannot both be given: system " ++
                "mode publishes the installed library's own headers and links " ++
                "the installed library, and this build compiles no artifact of " ++
                "its own to generate a dispatch from.  Drop one of them.",
            .{},
        );
    }

    if (use_system) {
        addSystemLibraryMode(b, target, optimize);
        return;
    }

    // Refuse dynamic linkage before creating steps if this target has no loader.
    if (linkage == .dynamic) {
        if (sharedObjectRefusal(b, target)) |reason| @panic(reason);
    }

    const generated = addGeneratedHeaders(b);

    const lib = addCoreLibrary(b, target, optimize, generated, bz2, linkage);
    b.installArtifact(lib);
    // Bind header install steps; the library is unusable without its headers.
    const header_installs = installHeaders(b);
    for (header_installs) |header| b.getInstallStep().dependOn(&header.step);

    // Install pkg-config and licence records with the library.
    const pkgconfig = b.addInstallFile(
        addPkgConfig(b, target, bz2),
        "lib/pkgconfig/htscodecs.pc",
    );
    b.getInstallStep().dependOn(&pkgconfig.step);
    installRecords(b);

    const published = addPublicModule(
        b,
        "htscodecs",
        target,
        optimize,
        lib,
        .vendored,
        bz2,
        runtime,
        .build_cache,
        null,
    );
    const fixtures = addFixturesModule(b, target, optimize);

    // Dependents and tests need build-cache rpaths; the installed demo needs a prefix-relative path.
    const both_loaders = needsBothLoaders(if (runtime) null else lib, target);
    const install_facade = if (both_loaders)
        addPublicModule(b, null, target, optimize, lib, .vendored, bz2, runtime, .install_tree, &published).module
    else
        published.module;

    const test_step = b.step("test", "Run the behavioural tests");
    for (test_files) |path| {
        const unit = b.addTest(.{
            .name = std.fs.path.stem(path),
            .root_module = testModule(b, path, target, optimize, published.module, fixtures),
        });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }

    // The installed demo and smoke step use the facade with the matching loader path.
    const demo = addDemo(b, "htscodecs-demo", target, optimize, install_facade, fixtures);
    b.installArtifact(demo);

    const run_demo = if (both_loaders)
        addDemo(b, "htscodecs-demo-run", target, optimize, published.module, fixtures)
    else
        demo;
    const smoke_run = b.addRunArtifact(run_demo);
    const smoke_step = b.step("smoke", "Run the example and print its deterministic output");
    smoke_step.dependOn(&smoke_run.step);
    smoke_run.addPassthruArgs();

    addInstalledHeaderProof(b, target, optimize, lib, header_installs);

    // Target names narrow the matrix; unknown names are reported by both graphs.
    const check_targets = b.option(
        []const u8,
        "check-targets",
        b.fmt(
            "Comma-separated subset of the cross matrix to check instead of the " ++
                "whole default matrix.  Default matrix: {s}.  Also accepted: {s}.",
            .{ knownTargetNames(b), knownExtraTargetNames(b) },
        ),
    );
    addCrossCheck(b, optimize, generated, bz2, .static, runtime, check_targets);
    addCrossCheck(b, optimize, generated, bz2, .dynamic, runtime, check_targets);

    addProvenanceGate(b);
}

/// Windows supports DLLs despite `DynamicLinker.kind == .none`; WASI has no shared-object loader.
fn targetCarriesSharedObject(target: std.Build.ResolvedTarget) bool {
    if (target.result.os.tag == .windows) return true;
    return std.Target.DynamicLinker.kind(target.result.os.tag) != .none;
}

/// Return a refusal instead of substituting static output when no dynamic linker exists.
fn sharedObjectRefusal(b: *std.Build, target: std.Build.ResolvedTarget) ?[]const u8 {
    if (targetCarriesSharedObject(target)) return null;
    return b.fmt(
        "-Dlinkage=dynamic was requested for {s}, whose OS has no dynamic " ++
            "linker (std.Target.DynamicLinker.kind is .none for that OS), so no " ++
            "shared object can be built or loaded for it. This build does not " ++
            "substitute a different artefact for the one that was asked for; " ++
            "build the static delivery for this target instead, which is the " ++
            "default.",
        .{@tagName(target.result.os.tag)},
    );
}

/// Generate `config.h` from the checked-in configuration and pin `version.h` to the release tag.
fn addGeneratedHeaders(b: *std.Build) std.Build.LazyPath {
    const files = b.addWriteFiles();
    _ = files.add("htscodecs_config/config.h",
        \\/* Generated by build.zig.  Do not edit. */
        \\#ifndef HTSCODECS_BUILD_CONFIG_H
        \\#define HTSCODECS_BUILD_CONFIG_H
        \\#include "htscodecs_config.h"
        \\#endif
        \\
    );
    _ = files.add("htscodecs_config/version.h", b.fmt(
        \\/* Generated by build.zig from the pinned upstream tag.  Do not edit. */
        \\#ifndef HTSCODECS_VERSION_H
        \\#define HTSCODECS_VERSION_H
        \\#define HTSCODECS_VERSION_TEXT "{s}"
        \\#endif
        \\
    , .{upstream_version}));
    return files.getDirectory();
}

fn addCIncludePaths(m: *std.Build.Module, b: *std.Build, generated: std.Build.LazyPath) void {
    // The SIMD kernels include generated `config.h` by bare name.
    m.addIncludePath(b.path("htscodecs"));
    m.addIncludePath(b.path("include"));
    m.addIncludePath(b.path("."));
    m.addIncludePath(generated);
    m.addIncludePath(generated.path(b, "htscodecs_config"));
}

/// Upstream links libm on Linux and BSD; this predicate also drives pkg-config.
fn splitsLibm(os_tag: std.Target.Os.Tag) bool {
    return switch (os_tag) {
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
        else => false,
    };
}

fn addCoreLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    generated: std.Build.LazyPath,
    bz2: bool,
    linkage: std.lang.LinkMode,
) *std.Build.Step.Compile {
    // Shared builds require PIC for scalar and ISA objects; static keeps the default.
    // Apply the same setting to separately compiled kernels.
    const pic: ?bool = if (linkage == .dynamic) true else null;

    const lib = b.addLibrary(.{
        .name = "htscodecs",
        .linkage = linkage,
        // Shared libraries carry the upstream libtool ABI version.
        .version = if (linkage == .dynamic) libtool_abi else null,
        // Windows needs a generated export definition; its headers have no `dllexport`.
        .win32_module_definition = if (linkage == .dynamic and target.result.ofmt == .coff)
            addWin32ModuleDefinition(b, target)
        else
            null,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = pic,
        }),
    });
    addCIncludePaths(lib.root_module, b, generated);
    lib.root_module.addCSourceFiles(.{
        .root = b.path("htscodecs"),
        .files = &scalar_sources,
        .flags = &c_flags,
    });

    if (splitsLibm(target.result.os.tag)) {
        lib.root_module.linkSystemLibrary("m", .{});
    }

    if (bz2) {
        lib.root_module.addCMacro("HTSCODECS_WITH_BZ2", "1");
        lib.root_module.linkSystemLibrary("bz2", .{});
    }

    for (simd_kernels) |kernel| {
        if (!targetBuildsKernel(target, kernel)) continue;
        var query = target.query;
        query.cpu_model = .baseline;
        query.cpu_features_add = .empty;
        query.cpu_features_sub = .empty;
        for (kernel.features) |feature| query.cpu_features_add.addFeature(@backingInt(feature));
        const object = b.addObject(.{
            .name = b.fmt("htscodecs_{s}", .{kernel.name}),
            .root_module = b.createModule(.{
                .target = b.resolveTargetQuery(query),
                .optimize = optimize,
                .link_libc = true,
                .pic = pic,
            }),
        });
        addCIncludePaths(object.root_module, b, generated);
        object.root_module.addCSourceFiles(.{
            .root = b.path("htscodecs"),
            .files = &.{kernel.source},
            .flags = &c_flags,
        });
        lib.root_module.addObject(object);
    }

    return lib;
}

/// Windows exports include only public definitions and ISA kernels built for this target.
fn addWin32ModuleDefinition(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) std.Build.LazyPath {
    const gpa = b.allocator;
    var text: std.ArrayList(u8) = .empty;
    text.appendSlice(gpa,
        \\; Generated by build.zig.  Do not edit.
        \\;
        \\; The exported C entry points of libhtscodecs for a Windows shared
        \\; build.  htscodecs decorates nothing: no public header carries
        \\; __declspec(dllexport), so this file is the whole export contract.
        \\; Every name below is a definition in a translation unit this build
        \\; compiles -- the scalar list from `scalar_sources`, the ISA list
        \\; from the kernel selected for this target -- and every one of them
        \\; is declared by a header under include/htscodecs/.  A name the
        \\; archive does not define is a link error here rather than a
        \\; missing export in a DLL somebody ships.
        \\
        \\EXPORTS
        \\
    ) catch @panic("OOM");
    for (public_symbols) |name| {
        text.print(gpa, "    {s}\n", .{name}) catch @panic("OOM");
    }
    for (simd_kernels) |kernel| {
        if (!targetBuildsKernel(target, kernel)) continue;
        for (kernel.exports) |name| {
            text.print(gpa, "    {s}\n", .{name}) catch @panic("OOM");
        }
    }
    return b.addWriteFiles().add("htscodecs.def", text.items);
}

/// Relocatable pkg-config metadata; links match the C graph and Version is the release, not ABI.
fn addPkgConfig(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    bz2: bool,
) std.Build.LazyPath {
    const needs_libm = splitsLibm(target.result.os.tag);
    return b.addWriteFiles().add("htscodecs.pc", b.fmt(
        \\prefix=${{pcfiledir}}/../..
        \\exec_prefix=${{prefix}}
        \\libdir=${{exec_prefix}}/lib
        \\includedir=${{prefix}}/include
        \\
        \\Name: htscodecs
        \\Description: CRAM codecs from samtools/htscodecs: rANS, a dynamic arithmetic coder, run-length coding, the name tokeniser and fqzcomp quality coding
        \\Version: {s}
        \\URL: https://github.com/samtools/htscodecs
        \\Cflags: -I${{includedir}}
        \\Libs: -L${{libdir}} -lhtscodecs
        \\Libs.private:{s}{s}
        \\
    , .{
        upstream_version,
        if (needs_libm) " -lm" else "",
        if (bz2) " -lbz2" else "",
    }));
}

/// Install licence, provenance and documentation records with the package.
fn installRecords(b: *std.Build) void {
    // Install-file steps require an explicit dependency on the install step.
    for (installed_licence_records) |name| {
        const install = b.addInstallFileWithDir(
            b.path(name),
            .prefix,
            b.fmt("share/licenses/htscodecs/{s}", .{name}),
        );
        b.getInstallStep().dependOn(&install.step);
    }
    for (installed_docs) |name| {
        const install = b.addInstallFileWithDir(
            b.path(name),
            .prefix,
            b.fmt("share/doc/htscodecs/{s}", .{name}),
        );
        b.getInstallStep().dependOn(&install.step);
    }
}

fn addSystemLibraryMode(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) void {
    // Pair installed headers with the prebuilt library to preserve ABI.
    // Linkage and bzip2 options cannot configure it; runtime mode is rejected.
    const published = addPublicModule(
        b,
        "htscodecs",
        target,
        optimize,
        null,
        .system,
        false,
        false,
        .build_cache,
        null,
    );
    const fixtures = addFixturesModule(b, target, optimize);

    const unit = b.addTest(.{
        .name = "system-interop",
        .root_module = testModule(b, "test/fixture_decode_test.zig", target, optimize, published.module, fixtures),
    });
    const run = b.addRunArtifact(unit);
    b.getInstallStep().dependOn(&run.step);

    const test_step = b.step("test", "Decode upstream's fixtures with the installed libhtscodecs");
    test_step.dependOn(&run.step);
}

/// Header source for translation.
const HeaderSource = enum {
    /// Vendored headers matching the source release being built.
    vendored,
    /// Installed headers matching the system library selected by `-fsys=htscodecs`.
    system,
};

/// Aro preprocesses and parses; target preprocessing runs first where Aro cannot read libc headers.
/// Both routes use the target's headers and compile macros.
const TranslationRoute = enum {
    /// Aro preprocesses and parses, from this repository's aggregate.
    aro,
    /// The target preprocessor expands the aggregate before Aro parses it.
    preprocessed,
};

/// Use target preprocessing where Aro mishandles libc headers:
/// NetBSD `_Pragma`, OpenBSD ILP32/MIPS declarations, and x86 Windows `_X86_`.
/// System mode uses installed headers and keeps the Aro route.
fn translationRoute(target: std.Build.ResolvedTarget, headers: HeaderSource) TranslationRoute {
    if (headers == .system) return .aro;
    return switch (target.result.os.tag) {
        .netbsd => .preprocessed,
        .openbsd => if (std.Target.ptrBitWidth(&target.result) != 64 or
            target.result.cpu.arch == .mips64 or target.result.cpu.arch == .mips64el)
            .preprocessed
        else
            .aro,
        .windows => if (target.result.cpu.arch == .x86) .preprocessed else .aro,
        else => .aro,
    };
}

/// Preprocess the target aggregate before Aro on libc-header cases Aro cannot parse.
/// Preserve C flags, bzip2 configuration and macros with `-dD`.
/// `-MD` records included headers as dependencies; do not invent target macros.
fn preprocessedAggregate(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    bz2: bool,
) std.Build.LazyPath {
    // Use this build's Zig compiler so preprocessing matches the C compiler.
    const run = b.addSystemCommand(&[_][]const u8{
        b.graph.zig_exe, "cc", "-E", "-dD", "-x", "c",
    });
    const triple = target.result.zigTriple(b.allocator) catch @panic("htscodecs: unspellable target");
    run.setName(b.fmt("preprocess htscodecs_all.h {s}", .{triple}));
    if (!target.query.isNative()) {
        run.addArg("-target");
        run.addArg(triple);
    }
    for (c_flags) |flag| run.addArg(flag);
    if (bz2) run.addArg("-DHTSCODECS_WITH_BZ2=1");
    run.addArg("-o");
    const preprocessed = run.addOutputFileArg2("htscodecs-translate.c", .{});
    run.addArg("-MD");
    _ = run.addDepFileOutputArg2("htscodecs-translate.d", .{ .prefix = "-MF" });
    run.addFileArg2(b.path("include/htscodecs_all.h"), .{});
    return preprocessed;
}

/// Shared translation and loader core keep `LoadSource` and `LoadError` type-identical.
const Facade = struct {
    module: *std.Build.Module,
    translate: *std.Build.Step.TranslateC,
    rt_core: ?*std.Build.Module,
};

fn addPublicModule(
    b: *std.Build,
    /// Published module name, or `null` for a private second facade.
    name: ?[]const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    /// Native artifact, or `null` when linking the installed library.
    lib: ?*std.Build.Step.Compile,
    headers: HeaderSource,
    bz2: bool,
    runtime: bool,
    loader: Loader,
    shared: ?*const Facade,
) Facade {
    // Reuse the translation when both loader facades target the same headers.
    const translate = if (shared) |previous| previous.translate else step: {
        const translate = b.addTranslateC(.{
            .root_source_file = switch (translationRoute(target, headers)) {
                .aro => b.path(switch (headers) {
                    .vendored => "include/htscodecs_all.h",
                    .system => "include/htscodecs_system.h",
                }),
                .preprocessed => preprocessedAggregate(b, target, bz2),
            },
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        switch (headers) {
            .vendored => {
                // Resolve vendored `htscodecs/...` includes from this tree.
                translate.addIncludePath(b.path("htscodecs"));
                translate.addIncludePath(b.path("include"));
                translate.addIncludePath(b.path("."));
            },
            .system => {
                // Use pkg-config for the installed headers and library.
                translate.linkSystemLibrary("htscodecs", .{ .use_pkg_config = .force });
            },
        }

        if (bz2) {
            // Match the C graph's optional feature macro.
            translate.defineCMacro("HTSCODECS_WITH_BZ2", "1");
        }
        break :step translate;
    };

    // A named module is public; the unnamed second facade is private.
    const module = if (name) |published_name|
        b.addModule(published_name, .{
            .root_source_file = b.path("root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        })
    else
        b.createModule(.{
            .root_source_file = b.path("root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

    // Linked mode imports the translation; runtime mode uses generated dispatch.
    // Both share one loader core, preserving `LoadSource` and `LoadError` identity.
    if (runtime) {
        module.addImport("c", graph.createModule(b, translate, target, optimize));
        return .{ .module = module, .translate = translate, .rt_core = null };
    }

    module.addImport("c", translate.createModule());
    const rt_core = if (shared) |previous|
        previous.rt_core.?
    else
        graph.createCoreModule(b, target, optimize);
    module.addImport("rt", rt_core);
    // Published modules use build-cache rpaths; the installed demo uses its private install-tree facade.
    switch (headers) {
        .vendored => linkForLoader(module, lib.?, target, loader),
        .system => module.linkSystemLibrary("htscodecs", .{ .use_pkg_config = .force }),
    }
    return .{ .module = module, .translate = translate, .rt_core = rt_core };
}

/// ELF/Mach-O install paths are `$ORIGIN/../lib` and `@loader_path/../lib`.
/// Windows loads DLLs beside the executable; targets without loaders need no path.
fn installedProgramRPath(target: std.Build.ResolvedTarget) ?[]const u8 {
    return switch (target.result.os.tag) {
        .windows, .wasi, .uefi => null,
        else => if (target.result.os.tag.isDarwin()) "@loader_path/../lib" else "$ORIGIN/../lib",
    };
}

/// Build-cache paths serve dependents; installed binaries use prefix-relative paths.
/// Do not embed a build-cache path in installed artifacts.
const Loader = enum {
    /// Installed programs use a prefix-relative runtime path.
    install_tree,
    /// Build outputs and dependents use the shared object's build-cache path.
    build_cache,
};

/// Link the library with the selected program's runtime path.
fn linkForLoader(
    module: *std.Build.Module,
    library: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    loader: Loader,
) void {
    // Windows uses its import library and has no rpath.
    if (library.linkage != .dynamic or target.result.os.tag == .windows) {
        module.linkLibrary(library);
        return;
    }
    switch (loader) {
        .build_cache => module.linkLibrary(library),
        .install_tree => {
            module.addObjectFile(library.getEmittedBin());
            if (installedProgramRPath(target)) |rpath| module.addRPathSpecial(rpath);
        },
    }
}

/// Shared dynamic libraries need separate build-cache and install-tree facades except on Windows.
fn needsBothLoaders(
    linked: ?*std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) bool {
    const library = linked orelse return false;
    return library.linkage == .dynamic and target.result.os.tag != .windows;
}

/// Private fixture module shared by tests and the example; not published.
fn addFixturesModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("fixtures.zig"),
        .target = target,
        .optimize = optimize,
    });
}

/// Build installed and smoke examples from the same source with the selected facade.
fn addDemo(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    facade: *std.Build.Module,
    fixtures: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(example_file),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "htscodecs", .module = facade },
                .{ .name = "fixtures", .module = fixtures },
            },
        }),
    });
}

fn testModule(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    published: *std.Build.Module,
    fixtures: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "htscodecs", .module = published },
            .{ .name = "fixtures", .module = fixtures },
        },
    });
}

/// Install headers where the aggregate's relative includes resolve.
fn installHeaders(b: *std.Build) []const *std.Build.Step.InstallFile {
    var steps: std.ArrayList(*std.Build.Step.InstallFile) = .empty;
    for (fork_headers) |name| {
        steps.append(b.allocator, b.addInstallHeaderFile(
            b.path(b.fmt("include/{s}", .{name})),
            b.fmt("htscodecs/{s}", .{name}),
        )) catch @panic("OOM");
    }
    for (upstream_headers) |name| {
        steps.append(b.allocator, b.addInstallHeaderFile(
            b.path(b.fmt("htscodecs/{s}", .{name})),
            b.fmt("htscodecs/{s}", .{name}),
        )) catch @panic("OOM");
    }
    return steps.items;
}

/// Compile and link two C translation units against the installed aggregate and library.
/// Exercises installed layout, cross-TU linkage and target-specific exports.
fn addInstalledHeaderProof(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    lib: *std.Build.Step.Compile,
    header_installs: []const *std.Build.Step.InstallFile,
) void {
    const files = b.addWriteFiles();

    const tu_a = files.add("htscodecs_header_tu_a.c",
        \\/* Generated by build.zig.  Do not edit.
        \\ *
        \\ * One translation unit of a C program that includes the
        \\ * *installed* aggregate header.  Written to fail if the
        \\ * installed include tree is incomplete, or if the header can
        \\ * only be used from a single translation unit.
        \\ */
        \\#include <htscodecs/htscodecs_all.h>
        \\#include <stddef.h>
        \\/* No upstream declaration is restated here.  Every name the
        \\   body below takes the address of is declared by the
        \\   *installed* header set this file included, and the archive it
        \\   links supplies the definition.  That is the whole proof: a
        \\   name the installed headers do not declare is a compile error
        \\   here, a name the archive does not export is a link error, and
        \\   a signature restated wrongly here would only add a third,
        \\   meaningless failure mode. */
        \\int htscodecs_header_tu_a(void);
        \\int htscodecs_header_tu_a(void) {
        \\    /* fqzcomp_qual.h: taking the address of an internal-linkage
        \\       constant is a use, so it stays in the object.  If the
        \\       header had given these external linkage, the other
        \\       translation unit's copies would collide at link time. */
        \\    static const int *const gflag = &GFLAG_MULTI_PARAM;
        \\    static const int *const pflag = &PFLAG_HAVE_QMAP;
        \\#if defined(HAVE_SSE4_1) && defined(HAVE_SSSE3) && defined(HAVE_POPCNT)
        \\    /* The decoder, not the encoder: the SSE4 kernel this build
        \\       compiles defines rans_uncompress_O0_32x16_sse4
        \\       (rANS_static32x16pr_sse4.c:462) and no
        \\       rans_compress_O0_32x16_sse4, whose only definition upstream
        \\       wrote is inside the `#if 0` block above it.  A pointer to
        \\       the undefined name would be a link error, not a proof. */
        \\    unsigned char *(*const sse4)(unsigned char *, unsigned int, unsigned char *, unsigned int) =
        \\        rans_uncompress_O0_32x16_sse4;
        \\#else
        \\    unsigned char *(*const sse4)(unsigned char *, unsigned int, unsigned char *, unsigned int) = 0;
        \\#endif
        \\#ifdef HAVE_AVX2
        \\    unsigned char *(*const avx2)(unsigned char *, unsigned int, unsigned char *, unsigned int *) =
        \\        rans_compress_O0_32x16_avx2;
        \\#else
        \\    unsigned char *(*const avx2)(unsigned char *, unsigned int, unsigned char *, unsigned int *) = 0;
        \\#endif
        \\#ifdef HAVE_AVX512
        \\    unsigned char *(*const avx512)(unsigned char *, unsigned int, unsigned char *, unsigned int *) =
        \\        rans_compress_O0_32x16_avx512;
        \\#else
        \\    unsigned char *(*const avx512)(unsigned char *, unsigned int, unsigned char *, unsigned int *) = 0;
        \\#endif
        \\    return *gflag + *pflag +
        \\        (sse4 != 0) + (avx2 != 0) + (avx512 != 0) +
        \\        (htscodecs_version != 0) + (hts_pack != 0) +
        \\        (hts_unpack != 0) + (hts_rle_encode != 0) + (hts_rle_decode != 0) +
        \\        (rans_compress != 0) + (rans_compress_bound_4x16 != 0) +
        \\        (rans_compress_to_4x16 != 0) + (rans_set_cpu != 0) +
        \\        (rans_compress_O0_32x16 != 0) + (arith_compress != 0) +
        \\        (arith_compress_bound != 0) + (tok3_encode_names != 0) +
        \\        (tok3_decode_names != 0) + (htscodecs_tls_alloc != 0) +
        \\        (htscodecs_tls_calloc != 0) + (htscodecs_tls_free != 0);
        \\}
        \\
    );

    const tu_b = files.add("htscodecs_header_tu_b.c",
        \\/* Generated by build.zig.  Do not edit.
        \\ *
        \\ * The second translation unit.  It includes the same installed
        \\ * aggregate and uses the fqzcomp flag constants too, which is
        \\ * the whole point: one definition per translation unit must
        \\ * link, not one per program.
        \\ */
        \\#include <htscodecs/htscodecs_all.h>
        \\int htscodecs_header_tu_a(void);
        \\int htscodecs_header_tu_b(void);
        \\int htscodecs_header_tu_b(void) {
        \\    static const int *const gflag = &GFLAG_HAVE_STAB;
        \\    static const int *const pflag = &PFLAG_HAVE_QTAB;
        \\    /* Types are upstream's, exactly: var_get_u32 returns int and
        \\       fast_log returns double, and clang treats a mismatched
        \\       function-pointer initialisation as an error. */
        \\    int (*const varint)(uint8_t *, const uint8_t *, uint32_t *) = var_get_u32;
        \\    double (*const log2)(double) = fast_log;
        \\    return *gflag + *pflag + (varint != 0) + (log2 != 0) +
        \\        htscodecs_header_tu_a();
        \\}
        \\int main(void) {
        \\    return htscodecs_header_tu_b() == 0;
        \\}
        \\
    );

    const proof = b.addExecutable(.{
        .name = "htscodecs-header-proof",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    // Generated sources require LazyPath, not root-relative string paths.
    proof.root_module.addCSourceFile(.{ .file = tu_a, .flags = &c_flags });
    proof.root_module.addCSourceFile(.{ .file = tu_b, .flags = &c_flags });
    // Use only installed headers; source-tree includes would bypass this proof.
    proof.root_module.addIncludePath(.{ .relative = .{ .base = .install_include } });
    proof.root_module.linkLibrary(lib);

    // Depend only on installed headers, not the full install step.
    for (header_installs) |install| proof.step.dependOn(&install.step);

    const build_only = b.step("headers",
        \\Compile and link two C translation units that each include the
        \\installed aggregate header.  Nothing is run.
        \\
    );
    build_only.dependOn(&proof.step);

    const run = b.addRunArtifact(proof);
    run.expectExitCode(0);
    const run_step = b.step("headers-run",
        \\Build the two-translation-unit header program and run it.
        \\
    );
    run_step.dependOn(&run.step);
}

fn addCrossCheck(
    b: *std.Build,
    optimize: std.lang.Optimize,
    generated: std.Build.LazyPath,
    bz2: bool,
    linkage: std.lang.LinkMode,
    runtime: bool,
    selected: ?[]const u8,
) void {
    // Register independent static and shared compile graphs.
    const route = if (runtime) "runtime-loaded (generated dispatch, native library not linked)" else "linked (translated header, native library linked)";
    const check_step = switch (linkage) {
        .static => b.step("check", b.fmt(
            \\Compile the C core, the translated interface, every public facade
            \\method, the tests and the example for the cross-target matrix,
            \\linked statically.
            \\Nothing is run: the test binaries are emitted as objects and the
            \\examples are compiled but never executed.
            \\
            \\Facade route: {s}.
            \\
        , .{route})),
        .dynamic => b.step("check-shared", b.fmt(
            \\The same compile-only matrix against the shared graph: every
            \\module position independent, each target's shared object really
            \\linked, and on Windows the generated export definition resolved.
            \\A target whose OS has no dynamic linker is not built there: that
            \\one row becomes a failing step carrying the reason, so the name
            \\stays in the matrix and every other row still compiles.
            \\Nothing is run.
            \\
            \\Facade route: {s}.
            \\
        , .{route})),
    };

    // Selected targets narrow the matrix; unknown names fail.

    var checked: usize = 0;
    for (matrix) |entry| {
        if (!wanted(entry.name, selected)) continue;
        addOneCheckTarget(b, check_step, entry.name, entry.query, optimize, generated, bz2, linkage, runtime);
        checked += 1;
    }

    if (selected != null) {
        for (extra_matrix) |entry| {
            if (!wanted(entry.name, selected)) continue;
            addOneCheckTarget(b, check_step, entry.name, entry.query, optimize, generated, bz2, linkage, runtime);
            checked += 1;
        }
    }

    if (selected) |list| {
        if (checked == 0) {
            _ = b.addFail(b.fmt(
                "{s}: -Dcheck-targets={s} named no target this build " ++
                    "knows.  Default matrix: {s}.  Also accepted: {s}.",
                .{ check_step.name, list, knownTargetNames(b), knownExtraTargetNames(b) },
            ));
        }
    }
}

fn knownExtraTargetNames(b: *std.Build) []const u8 {
    var names: [extra_matrix.len][]const u8 = undefined;
    for (&names, extra_matrix) |*slot, entry| slot.* = entry.name;
    return std.mem.join(b.allocator, ", ", &names) catch @panic("OOM");
}

fn knownTargetNames(b: *std.Build) []const u8 {
    var names: [matrix.len][]const u8 = undefined;
    for (&names, matrix) |*slot, entry| slot.* = entry.name;
    return std.mem.join(b.allocator, ", ", &names) catch @panic("OOM");
}

fn wanted(name: []const u8, selected: ?[]const u8) bool {
    const list = selected orelse return true;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t"), name)) return true;
    }
    return false;
}

/// Add one compile-only target graph.
fn addOneCheckTarget(
    b: *std.Build,
    check_step: *std.Build.Step,
    name: []const u8,
    query: std.Target.Query,
    optimize: std.lang.Optimize,
    generated: std.Build.LazyPath,
    bz2: bool,
    linkage: std.lang.LinkMode,
    runtime: bool,
) void {
    const target = b.resolveTargetQuery(query);
    // Keep unsupported dynamic targets as named failures; never substitute static output.
    if (linkage == .dynamic) {
        if (sharedObjectRefusal(b, target)) |reason| {
            check_step.dependOn(&b.addFail(b.fmt(
                "htscodecs: {s} row {s}: {s} No artifact was built for this " ++
                    "row, and nothing was substituted for it.",
                .{ check_step.name, name, reason },
            )).step);
            return;
        }
    }

    const lib = addCoreLibrary(b, target, optimize, generated, bz2, linkage);
    // Include linkage in each target name because static and shared graphs coexist.
    const tag = switch (linkage) {
        .static => "static",
        .dynamic => "shared",
    };
    // Compile-only checks use the published facade.
    const published = addPublicModule(
        b,
        b.fmt("htscodecs-check-{s}-{s}", .{ tag, name }),
        target,
        optimize,
        lib,
        .vendored,
        bz2,
        runtime,
        .build_cache,
        null,
    ).module;
    const fixtures = addFixturesModule(b, target, optimize);

    for (test_files) |path| {
        const unit = b.addTest(.{
            .name = b.fmt("{s}-{s}-{s}", .{ std.fs.path.stem(path), tag, name }),
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "htscodecs", .module = published },
                    .{ .name = "fixtures", .module = fixtures },
                },
            }),
            .emit_object = true,
        });
        check_step.dependOn(&unit.step);
    }

    const demo = b.addExecutable(.{
        .name = b.fmt("htscodecs-demo-{s}-{s}", .{ tag, name }),
        .root_module = b.createModule(.{
            .root_source_file = b.path(example_file),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "htscodecs", .module = published },
                .{ .name = "fixtures", .module = fixtures },
            },
        }),
    });
    check_step.dependOn(&demo.step);
}

fn addProvenanceGate(b: *std.Build) void {
    const gate = b.step("provenance", "Licence and provenance integrity gate");
    const history = b.step("provenance-history",
        \\Check that the pinned upstream commit is in this clone's history
        \\
    );

    // Check required records under the build root; this gate works offline.
    const io = b.graph.io;
    for (required_records) |path| {
        b.root.access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => gate.dependOn(&b.addFail(b.fmt(
                "provenance: required file '{s}' is missing.  The BSD licence " ++
                    "text, the upstream provenance record and the aggregate " ++
                    "public header are all part of what this fork " ++
                    "redistributes; do not remove them.",
                .{path},
            )).step),
            else => gate.dependOn(&b.addFail(b.fmt(
                "provenance: cannot read '{s}': {s}.",
                .{ path, @errorName(err) },
            )).step),
        };
    }

    // Check pinned history separately so source archives without `.git` can build.
    // Run Git from the package root, not the process working directory.
    const build_root = b.root.toString(b.allocator) catch @panic("OOM");
    const verify = b.addSystemCommand(&.{
        "git",      "-C", build_root,
        "cat-file", "-e", upstream_commit ++ "^{commit}",
    });
    verify.expectExitCode(0);
    history.dependOn(&verify.step);

    // Only the source-integrity half runs as part of every ordinary build.
    b.getInstallStep().dependOn(gate);
}
