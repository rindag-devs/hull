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
  stdenvNoCC,
  fetchurl,
}:

let
  version = "28_judge";
in
stdenvNoCC.mkDerivation {
  pname = "wasi-compiler-rt";

  inherit version;

  src = fetchurl {
    url = "https://github.com/aberter0x3f/wasi-sdk/releases/download/wasi-sdk-${version}/libclang_rt-${version}.0.tar.gz";
    hash = "sha256-D65ECDbH0MYLPbiF5F+Hr0CsY8imdDKsnSVIEsANPjM=";
  };

  installPhase = ''
    mkdir -p $out/lib
    cp -r wasm32-unknown-wasip1 $out/lib/wasm32-unknown-wasip1
    ln -s $out/lib/wasm32-unknown-wasip1 $out/lib/wasm32-wasi-wasip1
  '';
}
