# SPDX-License-Identifier: BSD-3-Clause

{ lib, stdenv, zig, linkage ? "static", bzip2 ? null }:

# Zig defaults to the build host; reject cross derivations.
assert stdenv.hostPlatform.system == stdenv.buildPlatform.system
  || builtins.throw
    "htscodecs: package.nix builds for the build platform only; a cross derivation would compile for the builder";

let
  version = "1.6.7";

  # Explicit `null` prevents `callPackage` from enabling optional bzip2.
  withBzip2 = bzip2 != null;

  # Exclude build and cache state; retain package sources and records.
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
  # A static archive cannot carry the optional bzip2 link dependency.
  propagatedBuildInputs = lib.optional withBzip2 bzip2.dev;

  dontConfigure = true;
  dontBuild = true;
  doCheck = false;
  # Own the install phase to avoid Zig hook defaults.
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
    # Per-file licence exceptions are listed in `NOTICE.md`.
    license = lib.licenses.bsd3;
    licenseFile = "${placeholder "out"}/share/licenses/htscodecs/LICENSE.md";
    platforms = lib.platforms.unix;
  };
}