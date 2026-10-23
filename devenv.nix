# SPDX-License-Identifier: BSD-3-Clause
# Task bodies start in the caller's directory, so each enters this package root.
# Zig caches stay outside the checkout and are passed to each task explicitly.
# Install tasks write under the caller's local cache.

{ pkgs, lib, ... }:
let
  # Dynamic checks omit targets without a dynamic linker; WASI has a refusal task.
  hosted-shared-targets =
    "x86_64-linux-gnu,aarch64-linux-gnu,aarch64-macos-none,x86_64-windows-gnu,riscv64-linux-gnu";

  # Quote the package root, including paths with spaces.
  sdkRoot = builtins.toString ./.;
  sdkRootArg = lib.escapeShellArg sdkRoot;

  # Stop if a task cannot enter this package's directory.
  inSdk = ''cd ${sdkRootArg} || exit 1'';

  # Keep task caches and install prefixes under the caller's local cache.
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

  # Give the separate consumer package its own cache and install prefix.
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
    # bzip2 supplies both the runtime library and development headers.
    pkgs.bzip2
    pkgs.bzip2.dev
  ];

  # Keep outputs lazy and disable optional bzip2 unless requested.
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

  # Use `exec` task bodies and pass job, cache and summary options explicitly.
  # Only install steps set a prefix; the remaining tasks do not install.
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

    # Pass only when dynamic linking is refused for WASI with the target's reason.
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