//! A real, separate package that consumes the htscodecs fork as a
//! dependency.
//!
//! It is deliberately a different package with its own manifest: that is
//! what proves the published module and artifact are usable through
//! `b.dependency(...).module(...)` alone, with no access to the fork's
//! build script, generated headers or fixture data.
//!
//!   zig build run        run the consumer (its own step, its own binary)
//!   zig build            install the consumer binary
//!
//!   zig build run -Druntime=true
//!                          forward the fork's runtime-loaded
//!                          configuration, so the same assertions run
//!                          against the generated dispatch and an
//!                          explicit `load` instead of direct calls.
//!                          Forwarded, not re-decided: the consumer
//!                          must build the dependency the way the
//!                          caller asked for.
//!
//!   zig build run -Dlinkage=dynamic
//!                          forward the fork's delivery option, so the
//!                          same assertions run against the shared
//!                          object instead of the archive the library
//!                          builds when nobody says otherwise.
//!                          Independent of
//!                          `-Druntime`: that one says whether the
//!                          module links the artifact at all, this one
//!                          says which artifact the library builds and
//!                          installs.  Naming neither leaves the
//!                          library's own defaults exactly as they are.
//!
//!   zig build run -Dbz2=true
//!                          forward the fork's optional bzip2 method, so
//!                          the consumer can build the core with
//!                          `HAVE_LIBBZ2` and link the same `-lbz2` the
//!                          installed pkg-config file records.  This is
//!                          the one option that changes what is compiled
//!                          into the archive and what the link closure
//!                          carries, so without it the consumer could only
//!                          ever exercise the configuration where that
//!                          method is absent.  It needs the libbz2
//!                          development files for the target; the
//!                          devenv shell carries them.  Independent of the
//!                          two above: `-Druntime` says how the module
//!                          reaches the artifact, `-Dlinkage` which
//!                          artifact is delivered, and this one what is
//!                          compiled into it.
//!
//! The assertions here are on behaviour a caller can rely on: a round trip
//! reproduces the input exactly, every codec the facade advertises is
//! reachable, the error surface is the documented one, and the raw
//! translated C interface is usable directly.  The independent
//! interoperability fixtures live in the fork's own tests, because those
//! are the only place the upstream corpus is available.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Forwarded rather than re-decided.  The consumer has no opinion about
    // which facade route it exercises; it must build the fork the way the
    // caller asked for, or `zig build run -Druntime=true` here would silently
    // test the linked route instead of the one that was requested.
    const runtime = b.option(
        bool,
        "runtime",
        "Build the fork's facade in its runtime-loaded configuration, so the " ++
            "consumer exercises `load` and the generated dispatch rather than " ++
            "direct calls.",
    ) orelse false;

    // Forwarded, and unnamed stays unnamed.  `std.Build` records a
    // dependency argument only when it carries a value: the enum arm is
    // guarded by `if (maybe_value) |v|` (`std/Build.zig:510-516`), and the
    // optional is unwrapped before that (`std/Build.zig:569-580`), so a
    // `null` here is not passed on at all.  The dependency's own
    // `-Dlinkage` is then simply not resolved and its `orelse .static`
    // policy stands.  Answering for it here instead would be a second
    // copy of a default that could drift away from the library's.
    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Forwarded to the htscodecs dependency: which artifact its build " ++
            "delivers and installs, the default static archive or a real " ++
            "shared object.  It selects the delivery and nothing else -- " ++
            "the codec sources, their flags and their fixtures are the " ++
            "same either way -- and it is independent of `-Druntime`, " ++
            "which decides whether the module reaches that artifact " ++
            "through a link line or through an explicit `load`.  Left " ++
            "unset, the library's own default applies.",
    );

    // Forwarded, and unnamed stays unnamed, for the same reason as
    // `linkage` above and for the same reason it cites: `std.Build` carries
    // an optional through `addUserInputOptionFromArg`, whose parameter is
    // `maybe_value: ?T` with the contract "If null, the value won't be
    // added" (lib/std/Build.zig:435-436) and whose `bool` arm is
    // `if (maybe_value) |v|` (`:503`), so a `null` here is not passed on at
    // all and the dependency's own `orelse false` policy stands.  Answering
    // for it here instead would be a second copy of a default that could
    // drift away from the library's.
    const bz2 = b.option(
        bool,
        "bz2",
        "Forwarded to the htscodecs dependency: compile the arithmetic " ++
            "coder's bzip2 external method (HAVE_LIBBZ2), which the C graph " ++
            "and the installed pkg-config file both have to know about, and " ++
            "which requires the libbz2 development files for the target.  " ++
            "Left unset, the library's own default applies.",
    );

    const dep = b.dependency("htscodecs", .{
        .target = target,
        .optimize = optimize,
        .runtime = runtime,
        .linkage = linkage,
        .bz2 = bz2,
    });

    const exe = b.addExecutable(.{
        .name = "htscodecs-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "htscodecs", .module = dep.module("htscodecs") },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the consumer and check its assertions");
    run_step.dependOn(&run.step);

    // The published module carries `$ORIGIN/../lib` -- the installed tree's own
    // search path -- and nothing else, so this program, which runs out of this
    // package's build cache where no `lib/` sits beside it, is told where the
    // shared object is. Zig's run step sets no loader search path of its own.
    // See `linkInstalledSibling` in the library's build.zig.
}
