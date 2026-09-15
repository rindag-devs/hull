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

# The WebAssembly data is platform independent. One build serves every target.
rec {
  compiler-rt = pkgs.callPackage ./compiler-rt.nix { };

  libc = pkgs.callPackage ./libc {
    inherit compiler-rt;
  };

  libstdcxx = pkgs.callPackage ./libstdcxx {
    inherit compiler-rt libc;
  };

  sysroot = pkgs.runCommandLocal "wasm32-wasi-wasip1-sysroot" { } ''
    mkdir -p $out
    cp -R -L --no-preserve=ownership,mode ${libc}/. $out/
    cp -R -L --no-preserve=ownership,mode ${libstdcxx}/. $out/
  '';
}
