# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  lib,
  stdenv,
  zig_0_17,
}:
stdenv.mkDerivation {
  pname = "zig-serial";
  version = "0.1.0";

  # Named rather than filtered, so that editing something outside this list
  # -- the flake, the workflow, a scratch file -- does not rebuild the package.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./build.zig
      ./build.zig.zon
      ./src
      ./tools
      ./LICENSES
      ./REUSE.toml
    ];
  };

  nativeBuildInputs = [ zig_0_17.hook ];

  # No dependencies, so nothing to hand Zig in place of the network. The
  # tests open pseudo-terminals, which the build sandbox provides.
  doCheck = true;

  # A library has nothing to install but its documentation.
  postInstall = ''
    zig build docs --prefix $out
  '';

  meta = {
    description = "Serial ports for Zig";
    homepage = "https://git.jcollie.dev/jeff/zig-serial";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix ++ lib.platforms.windows;
  };
}
