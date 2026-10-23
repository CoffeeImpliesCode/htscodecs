//! Separate package that consumes the public htscodecs module and artifact.
//! `zig build run` exercises the linked, dynamic-linkage, runtime-loading, and bzip2 configurations.
//! Unset options keep the dependency's defaults.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Forward the caller's route choice so runtime builds test the requested path.
    const runtime = b.option(
        bool,
        "runtime",
        "Build the fork's facade in its runtime-loaded configuration, so the " ++
            "consumer exercises `load` and the generated dispatch rather than " ++
            "direct calls.",
    ) orelse false;

    // Forward only explicit dependency options so each retains its own default.
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

    // The build-cache run step needs the installed shared library's directory.
}
