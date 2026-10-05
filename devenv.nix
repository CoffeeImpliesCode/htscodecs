# SPDX-License-Identifier: BSD-3-Clause
#
# Canonical development environment.  Tools and tasks only; the SDK package
# is not realised on shell entry.
#
# Three facts are load-bearing for every task below, and all three were wrong
# on 2026-10-04.
#
# 1. A task body runs with the *caller's* working directory.  Under the
#    canonical `devenv --from path:<this SDK>` entry that directory is a scratch
#    project holding `devenv.lock` and `.devenv/`, and none of `build.zig`,
#    `consumer/` or the provenance records this SDK checks.  So every body
#    changes into this module's own directory first, named here as
#    `builtins.toString ./.` -- `./.` is the directory of the file that writes
#    it, so it does not depend on where the caller stood, and `builtins.toString`
#    rather than an interpolated `${./.}` keeps it a plain path string instead
#    of asking Nix for a read-only store copy of this whole tree.  That is what
#    made `sdk:provenance` print `error: no build.zig file found, in the current
#    directory or any parent directories` and `consumer:run` print `cd: consumer:
#    No such file or directory`.
#
# 2. The Zig caches are the caller's, and `devenv tasks run --mode single` does
#    not run `enterShell`, so a body that relied on the shell hook to have set
#    them ran with Zig's own default instead -- `.zig-cache` beside the build
#    root, which is this checkout.  So every body resolves them itself, before
#    it reaches the compiler: a value the caller exported wins, a missing one
#    comes from `$XDG_CACHE_HOME` and then from `$TMPDIR`, and with neither set
#    the body names what is missing and stops.  `/tmp`, `/var/tmp`, a Nix store
#    path and this repository are all refused.  Each body then also passes the
#    local one as an explicit `--cache-dir`, so the location is stated rather
#    than inherited, and a caller's own `--cache-dir` at the end of its command
#    line still wins.
#
# 3. `zig build`'s own default prefix is `zig-out` beside the build root, which
#    is also this checkout, and a bare `zig build` *is* the install step.  So the
#    two bodies that install name a prefix under the caller's local cache; the
#    bodies that do not install are not given one.  See `choosePaths`.

{ pkgs, lib, ... }:
let
  # The five default-matrix rows whose OS has a dynamic linker, in the order
  # build.zig's own `matrix` declares them.  `wasm32-wasi` is the sixth and is
  # deliberately not here: `-Dlinkage=dynamic` is refused for it by name,
  # because `std.Target.DynamicLinker.kind` is `.none` for that OS, so a task
  # that asked for the whole matrix could never tell a hosted regression from
  # that expected refusal.  `sdk:check-shared-wasi-refusal` runs that row and
  # asserts the refusal instead.  The *static* matrix keeps all six: a static
  # delivery is a real delivery on that target, so `sdk:check` still walks it.
  hosted-shared-targets =
    "x86_64-linux-gnu,aarch64-linux-gnu,aarch64-macos-none,x86_64-windows-gnu,riscv64-linux-gnu";

  # This SDK's own directory, and the shell-quoted form every body starts from.
  # `lib.escapeShellArg` is this workspace's quoting convention
  # (`htscodecs/package.nix` uses the same function), so a checkout path holding
  # a space or a quote still reaches the shell as one argument.
  sdkRoot = builtins.toString ./.;
  sdkRootArg = lib.escapeShellArg sdkRoot;

  # The first line of every exec body.  The `|| exit 1` is not decoration: a
  # body that continued after a failed `cd` would build, or check, whatever
  # directory it happened to be standing in.
  inSdk = ''cd ${sdkRootArg} || exit 1'';

  # Where everything a run generates goes, decided in one place so two bodies
  # cannot disagree about it.  Two pieces of shell, and neither is a new name
  # the caller has to learn: the caches are `ZIG_LOCAL_CACHE_DIR` and
  # `ZIG_GLOBAL_CACHE_DIR`, which is what Zig itself reads, and the install
  # prefixes hang off the caller's local cache.
  choosePaths = ''
    if [ -n "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      :
    elif [ -n "''${XDG_CACHE_HOME:-}" ]; then
      ZIG_LOCAL_CACHE_DIR="$XDG_CACHE_HOME/htscodecs/zig-local-cache"
      export ZIG_LOCAL_CACHE_DIR
    elif [ -n "''${TMPDIR:-}" ]; then
      ZIG_LOCAL_CACHE_DIR="$TMPDIR/htscodecs/zig-local-cache"
      export ZIG_LOCAL_CACHE_DIR
    else
      echo "htscodecs: ZIG_LOCAL_CACHE_DIR, XDG_CACHE_HOME and TMPDIR are all" >&2
      echo "unset, so no build cache outside this checkout is known.  Export one" >&2
      echo "of them at an approved scratch mount and run the task again." >&2
      exit 1
    fi

    if [ -n "''${ZIG_GLOBAL_CACHE_DIR:-}" ]; then
      :
    elif [ -n "''${XDG_CACHE_HOME:-}" ]; then
      ZIG_GLOBAL_CACHE_DIR="$XDG_CACHE_HOME/htscodecs/zig-global-cache"
      export ZIG_GLOBAL_CACHE_DIR
    elif [ -n "''${TMPDIR:-}" ]; then
      ZIG_GLOBAL_CACHE_DIR="$TMPDIR/htscodecs/zig-global-cache"
      export ZIG_GLOBAL_CACHE_DIR
    else
      echo "htscodecs: ZIG_GLOBAL_CACHE_DIR, XDG_CACHE_HOME and TMPDIR are all" >&2
      echo "unset, so no global build cache outside this checkout is known." >&2
      echo "Export one of them at an approved scratch mount and run the task" >&2
      echo "again." >&2
      exit 1
    fi

    install_prefix="$ZIG_LOCAL_CACHE_DIR/htscodecs-prefix"
    mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR" "$install_prefix" || exit 1
  '';

  # `consumer/` is a separate package with its own build graph and its own
  # default prefix, so it gets its own pair under the caller's local cache
  # rather than writing into the SDK's.
  chooseConsumerPaths = ''
    consumer_cache_dir="$ZIG_LOCAL_CACHE_DIR/htscodecs-consumer-cache"
    consumer_prefix="$ZIG_LOCAL_CACHE_DIR/htscodecs-consumer-prefix"
    mkdir -p "$consumer_cache_dir" "$consumer_prefix" || exit 1
  '';
in
{
  packages = [
    pkgs.zig_0_16
    pkgs.pkg-config
    # bzip2 out carries the runtime library and command, dev the headers and
    # libbz2.so that -Dbz2=true compiles against.
    pkgs.bzip2
    pkgs.bzip2.dev
  ];

  # Lazy: same package.nix, same derivation, nothing built until asked for
  # with `devenv build outputs.static` / `outputs.shared`.  `bzip2 = null`
  # because callPackage would otherwise fill it and enable the optional
  # codec method.
  outputs = {
    static = pkgs.callPackage ./package.nix {
      zig = pkgs.zig_0_16;
      linkage = "static";
      bzip2 = null;
    };
    shared = pkgs.callPackage ./package.nix {
      zig = pkgs.zig_0_16;
      linkage = "dynamic";
      bzip2 = null;
    };
    default = pkgs.callPackage ./package.nix {
      zig = pkgs.zig_0_16;
      bzip2 = null;
    };
  };

  # `exec`, not `command`: the option a task runs with is `exec` (`command` is
  # not a task option, and the `did you mean` list says so). Names are quoted
  # whole, so the colon in `sdk:build` is part of the name and not syntax.
  #
  # Every body below carries the same three build-runner flags, because the
  # recipe asks for all three and a body missing one is a body that silently
  # drops a job, writes `.zig-cache/` into this checkout, or reports its
  # outcome without naming the steps: `-j8`, `--cache-dir` and `--summary all`.
  # None of these bodies forwarded caller flags before and none does now; a
  # flag the caller wants is added to the command below, not passed through, and
  # `devenv tasks run` on 2.4 cannot forward arguments to a task in any case.
  #
  # `--prefix` appears on exactly two routes, and the reason is in `build.zig`
  # rather than in a convention: a bare `zig build` *is* the install step
  # (`std.Build` makes the install step the default step, and `build.zig:549-562`,
  # `:985-994`, `:1047` and `:2145` hang the headers, the pkg-config file, the
  # licence records, the demo, the interop run and the provenance gate off it),
  # so `sdk:build` installs and must say where.  `consumer:run` installs for the
  # same reason from the other side: `consumer/build.zig:135-138` makes its
  # `run` step depend on its own install step.  Every other step named here is a
  # test, a smoke, a compile-only matrix, a header proof or the source-integrity
  # gate, and none of them depends on an install step, so none of them is given
  # a prefix it would not use.
  tasks = {
    "sdk:build" = {
      exec = ''
        ${inSdk}
        ${choosePaths}
        zig build --cache-dir "$ZIG_LOCAL_CACHE_DIR" --prefix "$install_prefix" -j8 --summary all
      '';
    };

    "sdk:test" = {
      exec = ''
        ${inSdk}
        ${choosePaths}
        zig build test --cache-dir "$ZIG_LOCAL_CACHE_DIR" -j8 --summary all
      '';
    };

    "sdk:test-release-safe" = {
      exec = ''
        ${inSdk}
        ${choosePaths}
        zig build test -Doptimize=ReleaseSafe --cache-dir "$ZIG_LOCAL_CACHE_DIR" -j8 --summary all
      '';
    };

    "sdk:smoke" = {
      exec = ''
        ${inSdk}
        ${choosePaths}
        zig build smoke --cache-dir "$ZIG_LOCAL_CACHE_DIR" -j8 --summary all
      '';
    };

    "sdk:check" = {
      exec = ''
        ${inSdk}
        ${choosePaths}
        zig build check --cache-dir "$ZIG_LOCAL_CACHE_DIR" -j8 --summary all
      '';
    };

    "sdk:check-shared" = {
      exec = ''
        ${inSdk}
        ${choosePaths}
        zig build check-shared -Dlinkage=dynamic --cache-dir "$ZIG_LOCAL_CACHE_DIR" -j8 -Dcheck-targets=${hosted-shared-targets} --summary all
      '';
    };

    # The one row that cannot carry a shared object.  This task *expects* a
    # non-zero exit: it passes only when `zig build` refused that row by name,
    # carrying the reason, and built nothing in its place.  An exit 0 here is
    # the failure -- it would mean no row was refused.  Nothing is written
    # outside the build tree: the output is captured in a shell variable and
    # printed, not spooled to a file.  The step it runs is the compile-only
    # shared matrix, which installs nothing, so it is given the cache, the job
    # count and the summary, but no prefix.
    "sdk:check-shared-wasi-refusal" = {
      exec = ''
        set -uo pipefail
        ${inSdk}
        ${choosePaths}
        if out="$(zig build check-shared -Dlinkage=dynamic --cache-dir "$ZIG_LOCAL_CACHE_DIR" -j8 -Dcheck-targets=wasm32-wasi --summary all 2>&1)"; then
          status=0
        else
          status=$?
        fi
        printf '%s\n' "$out"
        if [ "$status" -eq 0 ]; then
          echo "sdk:check-shared-wasi-refusal: exited 0, so no row was refused for want of a dynamic linker"
          exit 1
        fi
        for expected in \
          'check-shared row wasm32-wasi' \
          'std.Target.DynamicLinker.kind is .none for that OS' \
          'This build does not substitute a different artefact' \
          'build the static delivery for this target instead'; do
          case "$out" in
            *"$expected"*) ;;
            *)
              echo "sdk:check-shared-wasi-refusal: expected the shared-graph refusal to say: $expected"
              exit 1
              ;;
          esac
        done
        echo "sdk:check-shared-wasi-refusal: the wasm32-wasi row was refused by name, as expected"
      '';
    };

    "sdk:headers-run" = {
      exec = ''
        ${inSdk}
        ${choosePaths}
        zig build headers-run --cache-dir "$ZIG_LOCAL_CACHE_DIR" -j8 --summary all
      '';
    };

    "sdk:provenance" = {
      exec = ''
        ${inSdk}
        ${choosePaths}
        zig build provenance --cache-dir "$ZIG_LOCAL_CACHE_DIR" -j8 --summary all
      '';
    };

    # `consumer/` is a separate package: it names this one through a path
    # dependency and has its own build graph, so it is built and run from its
    # own directory under this SDK root, with its own cache and prefix.  A
    # failure here localises to the consumer rather than to the SDK.
    "consumer:run" = {
      exec = ''
        ${inSdk}
        ${choosePaths}
        ${chooseConsumerPaths}
        cd consumer || exit 1
        zig build run --cache-dir "$consumer_cache_dir" --prefix "$consumer_prefix" -j8 --summary all
      '';
    };
  };
}