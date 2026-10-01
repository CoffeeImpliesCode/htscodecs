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

    const dep = b.dependency("htscodecs", .{
        .target = target,
        .optimize = optimize,
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
}
