# SPDX-License-Identifier: BSD-3-Clause
#
# htscodecs 1.6.7, built from source with Zig 0.16.0.
#
# One uncurried function, one derivation.  `linkage` selects the variant and
# the entry points (flake.nix, devenv.nix) choose it.  Every installed path,
# C flag and source list belongs to build.zig; this file only runs it.
# See README.md and NOTICE.md.

{ lib, stdenv, zig, linkage ? "static", bzip2 ? null }:

# `zig build` with no -Dtarget compiles for the machine running it, so a
# cross derivation would silently produce the wrong architecture.
assert stdenv.hostPlatform.system == stdenv.buildPlatform.system
  || builtins.throw
    "htscodecs: package.nix builds for the build platform only; a cross derivation would compile for the builder";

let
  version = "1.6.7";

  # Off unless a bzip2 package is passed.  Entry points pass `bzip2 = null`
  # explicitly, because callPackage would otherwise fill it from the package
  # set and turn the optional codec method on by accident.
  withBzip2 = bzip2 != null;

  # VCS, caches, and Nix/devenv/direnv state only.  Sources, headers, tests,
  # fixtures, tools and licence records all stay.
  isState =
    name:
    name == ".git"
    || name == ".zig-cache"
    || name == "zig-cache"
    || name == "zig-out"
    || name == "zig-pkg"
    || name == ".devenv"
    || name == ".devenv.flake.nix"
    || name == "devenv.state"
    || name == ".direnv"
    || name == "result"
    || lib.hasPrefix "result-" name;

  src = lib.cleanSourceWith {
    name = "htscodecs-${version}";
    src = ./.;
    filter = path: type: !(isState (baseNameOf (toString path))) && lib.cleanSourceFilter path type;
  };
in
stdenv.mkDerivation {
  pname = "htscodecs";
  inherit version src;
  strictDeps = true;

  nativeBuildInputs = [ zig ];
  # A static archive records no link flags of its own, so a bzip2 build has to
  # publish the dependency to its consumers.
  propagatedBuildInputs = lib.optional withBzip2 bzip2.dev;

  dontConfigure = true;
  dontBuild = true;
  doCheck = false;
  # Own the phases: the hook's install phase would append --release=safe and
  # --prefix on its own.
  dontUseZigConfigure = true;
  dontUseZigBuild = true;
  dontUseZigCheck = true;
  dontUseZigInstall = true;

  installPhase = ''
    runHook preInstall

    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"

    # Plain shell: inside an indented Nix string a dollar-brace would be Nix
    # interpolation, so the fallback is written without braces.
    cores="$NIX_BUILD_CORES"
    [ -n "$cores" ] || cores=1

    zig build install \
      -j"$cores" \
      --prefix "$out" \
      -Doptimize=ReleaseSafe \
      -Dcpu=baseline \
      -Dlinkage=${lib.escapeShellArg linkage} \
      ${lib.optionalString withBzip2 "-Dbz2=true"} \
      --summary all

    runHook postInstall
  '';

  passthru = {
    inherit version linkage withBzip2;
    upstreamCommit = "b9fc194f772e45bb0a1f44b08cbf8697a1384bae";
  };

  meta = {
    description = "CRAM codecs: rANS, adaptive arithmetic, fqzcomp, name tokeniser";
    longDescription = ''
      The custom CRAM codecs used for EXTERNAL block types: two rANS variants,
      a dynamic arithmetic coder, name and quality-score codecs derived from
      fqzcomp, run-length coding and symbol packing.  Built from source by
      Zig 0.16.0; nothing is downloaded and no installed copy is used.
    '';
    homepage = "https://github.com/samtools/htscodecs";
    # BSD-3-Clause.  Three headers are public domain, two under a CC0 waiver:
    # NOTICE.md carries the per-file inventory.
    license = lib.licenses.bsd3;
    licenseFile = "${placeholder "out"}/share/licenses/htscodecs/LICENSE.md";
    platforms = lib.platforms.unix;
  };
}