# SPDX-License-Identifier: BSD-3-Clause
#
# htscodecs 1.6.7 built from source with Zig 0.16.0.  Outputs only; the
# build is ./package.nix.  Development is devenv (devenv.nix), so there is
# no devShell here to drift from it.

{
  description = "htscodecs 1.6.7 - CRAM codecs built from source with Zig 0.16.0 (BSD-3-Clause; three headers are public domain, see NOTICE.md)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/c7def046b9a883d46974757852106483d741586f";

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

      # `bzip2 = null` is explicit: callPackage fills an argument from the
      # package set whenever a matching attribute exists, default or not, so
      # omitting it would enable the optional codec method in every build.
      sdk = pkgs: linkage: pkgs.callPackage ./package.nix {
        zig = pkgs.zig_0_16;
        inherit linkage;
        bzip2 = null;
      };
    in
    {
      packages = forAllSystems (pkgs: rec {
        static = sdk pkgs "static";
        shared = sdk pkgs "dynamic";
        # Static: std.Build.LibraryOptions.linkage defaults to .static and
        # this SDK never set it.
        default = static;
      });
    };
}