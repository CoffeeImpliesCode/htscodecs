//! Zig 0.16 build for htscodecs.
//!
//! The library itself is the real, unmodified upstream C code.  This script
//! replaces the autotools `configure` + `make` pair: it decides the same
//! feature macros that configure.ac probes, compiles the same translation
//! units that htscodecs/Makefile.am lists, and exposes the result as a Zig
//! module, a library artifact, a translated C header set and a facade.
//!
//! Nothing is downloaded, no system copy is used, and no upstream script is
//! executed.  The only generated files are `config.h` and `version.h`,
//! which upstream's build also generates (the latter from `git describe`,
//! which this fork replaces with the pinned tag).
//!
//! Entry points
//! ------------
//!   zig build              install the library, headers and example
//!   zig build test         run the behavioural tests for the host target
//!   zig build smoke        run the example and print deterministic output
//!   zig build headers      compile and link two C translation units that
//!                          each include the *installed* aggregate header,
//!                          which is the only way to show the installed
//!                          include tree really works from more than one
//!                          translation unit
//!   zig build headers-run  build that program and run it
//!   zig build check        compile the facade, tests and example for the
//!                          six-target matrix without running anything
//!   zig build provenance   licence and provenance integrity gate, which
//!                          needs nothing but the sources
//!   zig build provenance-history
//!                          check that the pinned upstream commit is in
//!                          this clone's history; needs git and a .git
//!
//! Options
//! -------
//!   -Dbz2=true             compile the arithmetic coder's bzip2 external
//!                          method (needs libbz2 development files)
//!   -fsys=htscodecs        link a system libhtscodecs instead of building
//!                          the vendored sources.  This is the real
//!                          spelling: b.systemIntegrationOption is fed by
//!                          the build runner's -fsys=/-fno-sys= flags and
//!                          never appears in the -D option map.
//!   -Dcheck-targets=list   comma-separated subset of the cross matrix

const std = @import("std");

/// The upstream release this fork pins.  Kept in step with UPSTREAM.md.
const upstream_version = "1.6.7";
const upstream_commit = "b9fc194f772e45bb0a1f44b08cbf8697a1384bae";

/// Scalar translation units of libhtscodecs, mirroring
/// htscodecs/Makefile.am:libhtscodecs_base_src with the header-only entries
/// removed.  The Arm Neon 32x16 kernel and the three x86 kernels are added
/// separately because each needs its own ISA flags.
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

/// Compile the 32x16 ISA kernels with only their required features, separate
/// from the scalar dispatcher. Target features select Zig's machine code.
const SimdKernel = struct {
    name: []const u8,
    arch: std.Target.Cpu.Arch,
    source: []const u8,
    features: []const std.Target.x86.Feature = &.{},
};

const simd_kernels = [_]SimdKernel{
    .{
        .name = "sse4",
        .arch = .x86_64,
        .source = "rANS_static32x16pr_sse4.c",
        .features = &.{ .sse4_1, .ssse3, .popcnt },
    },
    .{
        .name = "avx2",
        .arch = .x86_64,
        .source = "rANS_static32x16pr_avx2.c",
        .features = &.{ .avx2, .popcnt },
    },
    .{
        .name = "avx512",
        .arch = .x86_64,
        .source = "rANS_static32x16pr_avx512.c",
        .features = &.{ .avx512f, .avx2, .evex512, .popcnt },
    },
    .{
        .name = "neon",
        .arch = .aarch64,
        .source = "rANS_static32x16pr_neon.c",
    },
};

const c_flags = [_][]const u8{"-std=gnu11"};

/// The installed include tree, in two parts.
///
/// `upstream_headers` are the headers under htscodecs/ that this package
/// installs beside the aggregate.  The list is upstream's own installed
/// set (`Makefile.am` `nobase_include_HEADERS`) plus the two headers
/// whose symbols this build compiles and would otherwise hide:
/// rANS_static32x16pr.h, which declares the per-ISA 32x16 entry points,
/// and utils.h, which declares the exported TLS allocator.  Every entry
/// here is included by include/htscodecs_all.h, so an aggregate that
/// names a header this table does not install fails the `headers` step
/// rather than at some consumer's compile line.
///
/// `fork_headers` are the aggregate and the fork-owned configuration
/// header the aggregate includes by bare name, so they have to sit in
/// the same installed directory as the aggregate itself.
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

/// The records this fork redistributes alongside the code.  Losing any
/// of these changes what the package is, not merely how it builds:
/// a private repository removes no upstream licence obligation.
const required_records = [_][]const u8{
    "LICENSE.md",
    "NOTICE.md",
    "UPSTREAM.md",
    "CHANGELOG.md",
    "README.zig.md",
};

/// The cross-compilation matrix.  `check` walks this list and builds every
/// entry in it.  Nothing is pre-judged: if a target turns out to need
/// something this machine does not have, that is for the gate to report,
/// not for the build script to guess at in advance.
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
        // Note: in Zig 0.16 `Abi.default` maps .macos to .none, so this is
        // the ordinary, normal macOS ABI rather than a libc-less one.  It
        // is in the matrix because it was asked for; whether this machine
        // can satisfy its prerequisites is a gate observation, not a build
        // script assumption.
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

/// Targets outside the requested matrix, buildable only when named
/// explicitly with -Dcheck-targets.  They are spelled without an ABI so the
/// toolchain picks its own default; whether this machine can satisfy their
/// prerequisites is a gate observation.
const extra_matrix = [_]struct { name: []const u8, query: std.Target.Query }{
    .{ .name = "aarch64-macos", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    .{ .name = "x86_64-macos", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
    .{ .name = "aarch64-windows-gnu", .query = .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu } },
};

/// Behavioural test files.  `test` runs them for the host target and
/// `check` compiles them, as objects, for every matrix target.  They are
/// the deliberate callers of the public facade: each method below is
/// invoked by a test that asserts something about its result, which is
/// what instantiates its body.  Reflection is deliberately not used
/// instead; see FORK-NOTES.md.
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
    const use_system = b.systemIntegrationOption("htscodecs", .{
        .default = false,
    });

    if (use_system) {
        addSystemLibraryMode(b, target, optimize);
        return;
    }

    const generated = addGeneratedHeaders(b);

    const lib = addCoreLibrary(b, target, optimize, generated, bz2);
    b.installArtifact(lib);
    const header_installs = installHeaders(b);

    const published = addPublicModule(b, "htscodecs", target, optimize, lib, .vendored, bz2);
    const fixtures = addFixturesModule(b, target, optimize, "");

    // --- tests -----------------------------------------------------------
    const test_step = b.step("test", "Run the behavioural tests");
    for (test_files) |path| {
        const unit = b.addTest(.{
            .name = std.fs.path.stem(path),
            .root_module = testModule(b, path, target, optimize, published, fixtures),
        });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }

    // --- example ---------------------------------------------------------
    const demo = b.addExecutable(.{
        .name = "htscodecs-demo",
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
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    const smoke_step = b.step("smoke", "Run the example and print its deterministic output");
    smoke_step.dependOn(&run_demo.step);
    if (b.args) |args| run_demo.addArgs(args);

    // --- installed include tree, from more than one translation unit -----
    addInstalledHeaderProof(b, target, optimize, lib, header_installs);

    // --- cross-target check ----------------------------------------------
    addCrossCheck(b, optimize, generated, bz2);

    // --- source-integrity and history gates -------------------------------
    addProvenanceGate(b);
}

// ---------------------------------------------------------------------------
// Generated headers
// ---------------------------------------------------------------------------

/// Writes the two files upstream's build generates.
///
/// `version.h` upstream derives from `git describe`; a pinned release does
/// not need git at build time, so the tag is baked in.  `config.h` is the
/// autoconf-shaped header every upstream .c includes; it is a one-line
/// shim so that the real policy lives in the checked-in
/// include/htscodecs_config.h and is shared with translate-c.
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
    // One buffer, built with b.fmt: the version text is a value, so the
    // file cannot be assembled with a compile-time `++`.
    _ = files.add("htscodecs_config/version.h", b.fmt(
        \\/* Generated by build.zig from the pinned upstream tag.  Do not edit. */
        \\#ifndef HTSCODECS_VERSION_H
        \\#define HTSCODECS_VERSION_H
        \\#define HTSCODECS_VERSION_TEXT "{s}"
        \\#endif
        \\
    , .{upstream_version}));
    // The directory, not one of the files: both generated headers live
    // under htscodecs_config/, and the C sources reach them by the bare
    // names upstream uses.
    return files.getDirectory();
}

fn addCIncludePaths(m: *std.Build.Module, b: *std.Build, generated: std.Build.LazyPath) void {
    // htscodecs/ for the sources' own quoted includes,
    // include/ for htscodecs_config.h,
    // the repository root for the "htscodecs/..." spelling,
    // the generated directory for the "htscodecs_config/version.h" spelling,
    // and the htscodecs_config/ subdirectory itself so a bare `#include
    // "config.h"` resolves.  The SIMD kernels open with that bare include
    // (rANS_static32x16pr_avx2.c:34, rANS_static32x16pr_avx512.c:40) and the
    // headers reach version.h the same way, so the subdirectory is not
    // optional: without it those translation units do not compile.
    m.addIncludePath(b.path("htscodecs"));
    m.addIncludePath(b.path("include"));
    m.addIncludePath(b.path("."));
    m.addIncludePath(generated);
    m.addIncludePath(generated.path(b, "htscodecs_config"));
}

// ---------------------------------------------------------------------------
// The C library
// ---------------------------------------------------------------------------

fn addCoreLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    generated: std.Build.LazyPath,
    bz2: bool,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "htscodecs",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    addCIncludePaths(lib.root_module, b, generated);
    lib.root_module.addCSourceFiles(.{
        .root = b.path("htscodecs"),
        .files = &scalar_sources,
        .flags = &c_flags,
    });

    if (bz2) {
        lib.root_module.addCMacro("HTSCODECS_WITH_BZ2", "1");
        lib.root_module.linkSystemLibrary("bz2", .{});
    }

    for (simd_kernels) |kernel| {
        if (target.result.cpu.arch != kernel.arch) continue;
        var query = target.query;
        query.cpu_model = .baseline;
        query.cpu_features_add = .empty;
        query.cpu_features_sub = .empty;
        for (kernel.features) |feature| query.cpu_features_add.addFeature(@intFromEnum(feature));
        const object = b.addObject(.{
            .name = b.fmt("htscodecs_{s}", .{kernel.name}),
            .root_module = b.createModule(.{
                .target = b.resolveTargetQuery(query),
                .optimize = optimize,
                .link_libc = true,
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

fn addSystemLibraryMode(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    // Same public module and ABI contract, but the compiled library comes
    // from the system instead of this repository, and the translated
    // interface is built from the *system's* headers rather than this
    // tree's.  Translating the bundled v1.6.7 headers and linking an
    // older installed library would describe an ABI that may not be the
    // one on disk, so the two are always taken from the same place.
    const shim = b.addLibrary(.{
        .name = "htscodecs",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    shim.root_module.linkSystemLibrary("htscodecs", .{});

    // The option does not reach the translation: in this mode the
    // installed library's own headers decide what it was built with, and
    // this fork's -Dbz2 says nothing about that.
    const published = addPublicModule(b, "htscodecs", target, optimize, shim, .system, false);
    const fixtures = addFixturesModule(b, target, optimize, "");

    // The interoperability suite is the right check here: an installed
    // libhtscodecs has to decode upstream's own checked-in streams, and
    // that is a claim about the library actually on the system rather
    // than about anything this repository compiled.
    const unit = b.addTest(.{
        .name = "system-interop",
        .root_module = testModule(b, "test/fixture_decode_test.zig", target, optimize, published, fixtures),
    });
    const run = b.addRunArtifact(unit);
    run.step.dependOn(&shim.step);
    b.getInstallStep().dependOn(&run.step);

    const test_step = b.step("test", "Decode upstream's fixtures with the installed libhtscodecs");
    test_step.dependOn(&run.step);
}

// ---------------------------------------------------------------------------
// Published module and translated C
// ---------------------------------------------------------------------------

/// Which headers the translated interface is built from.
const HeaderSource = enum {
    /// include/htscodecs_all.h plus this repository's upstream headers.
    /// Used for the vendored build, where the library and the headers are
    /// the same pinned revision.
    vendored,
    /// include/htscodecs_system.h, which pulls the installed headers off
    /// the system include path.  Used with -fsys=htscodecs, so the
    /// interface describes the library that is actually linked.
    system,
};

fn addPublicModule(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib: *std.Build.Step.Compile,
    headers: HeaderSource,
    bz2: bool,
) *std.Build.Module {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path(switch (headers) {
            .vendored => "include/htscodecs_all.h",
            .system => "include/htscodecs_system.h",
        }),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (headers == .vendored) {
        // The aggregate already uses relative includes; these make the
        // "htscodecs/..." spelling work for anything that reaches for it.
        translate.addIncludePath(b.path("htscodecs"));
        translate.addIncludePath(b.path("include"));
        translate.addIncludePath(b.path("."));
    }

    if (bz2) {
        // The same decision the C compilation gets, so the archive and
        // its translated interface cannot describe different builds.  No
        // installed public header is guarded by HAVE_LIBBZ2 today, so
        // this changes no declaration; it is here so that the answer
        // comes from one place rather than two that may drift.
        translate.defineCMacro("HTSCODECS_WITH_BZ2", "1");
    }

    const module = b.addModule(name, .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("c", translate.createModule());
    module.linkLibrary(lib);
    return module;
}

/// Upstream's test data, embedded so the tests are hermetic.  This module
/// is not part of the public package surface; only the tests and the
/// example import it.  `suffix` keeps the per-target names unique inside a
/// single build graph.
fn addFixturesModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    suffix: []const u8,
) *std.Build.Module {
    return b.addModule(b.fmt("htscodecs_fixtures{s}", .{suffix}), .{
        .root_source_file = b.path("fixtures.zig"),
        .target = target,
        .optimize = optimize,
    });
}

fn testModule(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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

// ---------------------------------------------------------------------------
// Installed headers
// ---------------------------------------------------------------------------

/// Installs the public include tree and returns the install steps, so the
/// header proof can depend on the headers and nothing else.
///
/// The installed layout mirrors the aggregate header's relative includes:
/// `include/htscodecs/htscodecs_all.h` reaches every upstream header as
/// `../htscodecs/<name>.h` from its own directory, and it reaches the
/// fork-owned configuration header as `htscodecs_config.h` from that same
/// directory.  Both spellings work from the source tree as well, which is
/// why `build.zig` needs no extra -I flags to find them.
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

// ---------------------------------------------------------------------------
// The installed include tree, from more than one translation unit
// ---------------------------------------------------------------------------

/// Compiles two C translation units that each include the *installed*
/// aggregate header, links them together, and optionally runs the result.
///
/// What this proves, and what nothing else here can:
///
///   * The installed layout resolves.  `../htscodecs/<name>.h` and the
///     bare `htscodecs_config.h` both have to work from
///     `<prefix>/include/htscodecs/`, which is a different directory
///     arrangement from the source tree the translation runs against.
///   * The header set the package installs is the header set the
///     aggregate needs.  A `#include` naming a header this build does not
///     install is a compile error here, not at a consumer's.
///   * The header is safe to include from more than one translation unit
///     of one program.  Upstream's `fqzcomp_qual.h` declares its flag
///     bits as `static const int` file-scope *definitions*; if anything
///     in the include chain gave them external linkage, both translation
///     units would define them and the link would fail with duplicate
///     symbols.  Only a real two-translation-unit link can show that.
///   * Every symbol named below is actually exported by the archive this
///     build produced, taken from the compiled library rather than from a
///     header on disk.
///
/// The per-ISA 32x16 entry points are referenced under the very macros
/// the installed configuration header derives from the target, so the
/// target-derived ISA decision is exercised rather than assumed.
fn addInstalledHeaderProof(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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
        \\    unsigned char *(*const sse4)(unsigned char *, unsigned int, unsigned char *, unsigned int *) =
        \\        rans_compress_O0_32x16_sse4;
        \\#else
        \\    unsigned char *(*const sse4)(unsigned char *, unsigned int, unsigned char *, unsigned int *) = 0;
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
    // Both translation units are generated, so they are handed over as
    // `LazyPath` values rather than as names relative to a root directory:
    // `addCSourceFiles` takes `[]const u8` paths, which cannot express a file
    // this build has not written yet.
    proof.root_module.addCSourceFile(.{ .file = tu_a, .flags = &c_flags });
    proof.root_module.addCSourceFile(.{ .file = tu_b, .flags = &c_flags });
    // The installed include *directory*, and nothing else: if the
    // aggregate resolved from this tree by accident the proof would prove
    // nothing about what this package installs.  The header directory is
    // what makes `<htscodecs/htscodecs_all.h>` resolve, and it is already
    // absolute, so `cwd_relative` is the LazyPath form that carries it.
    proof.root_module.addIncludePath(.{
        .cwd_relative = b.getInstallPath(.header, ""),
    });
    proof.root_module.linkLibrary(lib);

    // Only the headers, not the whole install step: this proof has no
    // business building the example.
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

// ---------------------------------------------------------------------------
// Cross-target check
// ---------------------------------------------------------------------------

fn addCrossCheck(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    generated: std.Build.LazyPath,
    bz2: bool,
) void {
    const check_step = b.step("check",
        \\Compile the C core, the translated interface, every public facade
        \\method, the tests and the example for the cross-target matrix.
        \\Nothing is run: the test binaries are emitted as objects and the
        \\examples are compiled but never executed.
        \\
    );

    // Selecting nothing means the whole default matrix.  Naming targets
    // narrows the default matrix to those, and additionally enables any
    // name from the opt-in list below.  A name that is in neither list is
    // an error rather than a silent no-op.
    const selected = b.option(
        []const u8,
        "check-targets",
        b.fmt(
            "Comma-separated subset of the cross matrix to check instead of the " ++
                "whole default matrix.  Default matrix: {s}.  Also accepted: {s}.",
            .{ knownTargetNames(b), knownExtraTargetNames(b) },
        ),
    );

    var checked: usize = 0;
    for (matrix) |entry| {
        if (!wanted(entry.name, selected)) continue;
        addOneCheckTarget(b, check_step, entry.name, entry.query, optimize, generated, bz2);
        checked += 1;
    }

    if (selected != null) {
        for (extra_matrix) |entry| {
            if (!wanted(entry.name, selected)) continue;
            addOneCheckTarget(b, check_step, entry.name, entry.query, optimize, generated, bz2);
            checked += 1;
        }
    }

    if (selected) |list| {
        if (checked == 0) {
            _ = b.addFail(b.fmt(
                "zig build check: -Dcheck-targets={s} named no target this build " ++
                    "knows.  Default matrix: {s}.  Also accepted: {s}.",
                .{ list, knownTargetNames(b), knownExtraTargetNames(b) },
            ));
        }
    }
}

/// The target names, joined from the tables above rather than written out
/// twice, so the help text and the failure message can only ever name the
/// targets the check actually walks.
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

/// Builds one matrix entry.
///
/// The C archive is compiled, the public header is translated, every test
/// file is compiled with `emit_object` so the Zig front end runs over its
/// bodies, and the example is compiled into an executable.  Nothing is
/// executed.
///
/// The tests are the deliberate callers of the facade.  Each public method
/// is invoked by a test that asserts something about the result, and
/// compiling that test for this target is what instantiates the method's
/// body here.  Reflection over the module is deliberately not used as the
/// mechanism: resolving a declaration's type says nothing about whether its
/// body type-checks, and a reflection-only test can only ever pass.
fn addOneCheckTarget(
    b: *std.Build,
    check_step: *std.Build.Step,
    name: []const u8,
    query: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
    generated: std.Build.LazyPath,
    bz2: bool,
) void {
    const target = b.resolveTargetQuery(query);
    const lib = addCoreLibrary(b, target, optimize, generated, bz2);
    const published = addPublicModule(
        b,
        b.fmt("htscodecs-check-{s}", .{name}),
        target,
        optimize,
        lib,
        .vendored,
        bz2,
    );
    const fixtures = addFixturesModule(b, target, optimize, b.fmt("-{s}", .{name}));

    for (test_files) |path| {
        const unit = b.addTest(.{
            .name = b.fmt("{s}-{s}", .{ std.fs.path.stem(path), name }),
            .root_module = testModule(b, path, target, optimize, published, fixtures),
            .emit_object = true,
        });
        check_step.dependOn(&unit.step);
    }

    const demo = b.addExecutable(.{
        .name = b.fmt("htscodecs-demo-{s}", .{name}),
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

// ---------------------------------------------------------------------------
// Licence and provenance gate
// ---------------------------------------------------------------------------

fn addProvenanceGate(b: *std.Build) void {
    const gate = b.step("provenance", "Licence and provenance integrity gate");
    const history = b.step("provenance-history",
        \\Check that the pinned upstream commit is in this clone's history
        \\
    );

    // Half one: the records this fork redistributes are present.  That is a
    // property of the sources alone, so it holds offline, in a tree with no
    // git at all, and it belongs to every ordinary build.
    //
    // The path is resolved against the package build root rather than the
    // process working directory, so the gate examines this tree however the
    // build was invoked.  In Zig 0.16 `std.fs` has no `cwd` and every
    // `Io.Dir` method takes the Io as a parameter, so this is exactly
    // `b.build_root.handle.access(b.graph.io, path, .{})`.
    const io = b.graph.io;
    for (required_records) |path| {
        b.build_root.handle.access(io, path, .{}) catch |err| switch (err) {
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

    // Half two: the pinned upstream commit must still be reachable in the
    // preserved history, or UPSTREAM.md describes a tree this repository
    // does not have.  That is a property of a clone, not of a source
    // package, so it is a step of its own: a tarball or a vendored copy
    // without .git must still build offline.  Asked for where the history is
    // absent, `git` fails and the step fails -- it never reports a success
    // it did not observe.
    //
    // `-C` takes the build root rather than `.`, for the same reason the
    // file check above does.
    const verify = b.addSystemCommand(&.{
        "git",      "-C", b.build_root.path orelse ".",
        "cat-file", "-e", upstream_commit ++ "^{commit}",
    });
    verify.expectExitCode(0);
    history.dependOn(&verify.step);

    // Only the source-integrity half runs as part of every ordinary build.
    b.getInstallStep().dependOn(gate);
}
