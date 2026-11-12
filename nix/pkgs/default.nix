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
  wasmSysroot,
  craneLib,
  src,
  # The WebAssembly clang wrapper of this toolset. The wrapper ships in a
  # bundle, so its package set is the set of the toolset.
  wasmClang,
  # The WebAssembly clang wrapper of the build machine. The tests of the CLI
  # run there.
  buildWasmClang,
  # The monitor renders the progress of `nix build`. Only a command of the
  # build machine starts `nix build`. A null value omits the wrapper of the CLI.
  nixOutputMonitor,
}:

let
  wasm32-wasi-wasip1 = wasmSysroot // {
    clang = wasmClang;
  };

  linuxOnlyPkgs = rec {
    nix-user-chroot = pkgs.callPackage ./nix-user-chroot { };

    talloc-static = pkgs.callPackage ./talloc-static.nix { };

    proot-static = pkgs.callPackage ./proot-static.nix {
      inherit talloc-static;
    };
  };
in
{
  default = pkgs.callPackage ./hull-cli.nix {
    inherit
      craneLib
      src
      buildWasmClang
      nixOutputMonitor
      ;
  };

  inherit wasm32-wasi-wasip1;
}
// pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux linuxOnlyPkgs
