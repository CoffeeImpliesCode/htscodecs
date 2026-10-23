# SPDX-License-Identifier: BSD-3-Clause

{
  description = "htscodecs 1.6.7 - CRAM codecs built from source with Zig 0.17.0 (BSD-3-Clause; three headers are public domain, see NOTICE.md)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems =
        f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Explicit null prevents callPackage from enabling bzip2.
      sdk = pkgs: linkage: pkgs.callPackage ./package.nix {
        zig = pkgs.zig_0_17;
        inherit linkage;
        bzip2 = null;
      };
    in
    {
      packages = forAllSystems (pkgs: rec {
        static = sdk pkgs "static";
        shared = sdk pkgs "dynamic";
        default = static;
      });
    };
}