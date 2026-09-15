/*
  This file is part of Hull.

  Hull is free software: you can redistribute it and/or modify it under the terms of the GNU
  Lesser General Public License as published by the Free Software Foundation, either version 3 of
  the License, or (at your option) any later version.

  Hull is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
  the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser
  General Public License for more details.

  You should have received a copy of the GNU Lesser General Public License along with Hull. If
  not, see <https://www.gnu.org/licenses/>.
*/

{
  pkgs,
  craneLib,
  src,
  # The WebAssembly clang wrapper of the build machine. The tests of the CLI
  # run there.
  buildWasmClang,
  # The monitor renders the progress of `nix build`. Only a command of the
  # build machine starts `nix build`. A null value omits the wrapper.
  nixOutputMonitor,
}:

craneLib.buildPackage {
  inherit src;

  # The tests of the CLI run on the build machine. They compile WebAssembly
  # programs with the wasm clang of that machine.
  nativeBuildInputs = [
    pkgs.makeBinaryWrapper
    buildWasmClang
  ];

  # The wrapper puts the monitor on the PATH of the user. The monitor renders
  # the progress of `nix build`, and only a build-machine command starts
  # `nix build`.
  postInstall = pkgs.lib.optionalString (nixOutputMonitor != null) ''
    wrapProgram $out/bin/hull \
      --prefix PATH : ${pkgs.lib.makeBinPath [ nixOutputMonitor ]}
  '';

  meta = {
    license = pkgs.lib.licenses.lgpl3Plus;
    mainProgram = "hull";
  };
}
