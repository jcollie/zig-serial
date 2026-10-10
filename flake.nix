# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "zig-serial: serial ports for Zig";

  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    };
  };

  outputs =
    {
      nixpkgs,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      makePackages =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = makePackages system;
        in
        rec {
          zig-serial = pkgs.callPackage ./package.nix { };
          default = zig-serial;
        }
      );

      # Only where an amd64 FreeBSD guest can be run under KVM.
      checks.x86_64-linux =
        let
          pkgs = makePackages "x86_64-linux";
        in
        {
          freebsd = pkgs.callPackage ./tests/freebsd { inherit (pkgs.callPackage ./package.nix { }) src; };
        };

      devShells = forAllSystems (
        system:
        let
          pkgs = makePackages system;
        in
        {
          default = pkgs.mkShell {
            name = "zig-serial";
            nativeBuildInputs = [
              pkgs.zig_0_17
              pkgs.git-pages-cli
              pkgs.reuse
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.kcov
              pkgs.perf
            ];
          };
        }
      );
    };
}
