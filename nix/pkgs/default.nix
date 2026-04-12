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
}:

let
  linuxOnlyPkgs = rec {
    talloc-static = pkgs.callPackage ./talloc-static { };
    proot-static = pkgs.callPackage ./proot-static {
      inherit talloc-static;
    };
  };
in
{
  nix-user-chroot = pkgs.callPackage ./nix-user-chroot { };
}
// pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux linuxOnlyPkgs
// {
  wasm32-wasi-wasip1 = rec {
    compiler-rt = pkgs.callPackage ./compiler-rt.nix { };
    libc = pkgs.callPackage ./libc {
      inherit compiler-rt;
    };
    libstdcxx = pkgs.callPackage ./libstdcxx {
      inherit compiler-rt libc;
    };
    sysroot = pkgs.symlinkJoin {
      name = "wasm32-wasi-wasip1-sysroot";
      paths = [
        libc
        libstdcxx
      ];
    };
    clang = pkgs.callPackage ./clang.nix {
      inherit compiler-rt sysroot;
    };
  };
}
