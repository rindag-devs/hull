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
  pname = "wasi-sysroot";

  inherit version;

  src = fetchurl {
    url = "https://github.com/aberter0x3f/wasi-sdk/releases/download/wasi-sdk-${version}/wasi-sysroot-${version}.0.tar.gz";
    hash = "sha256-E81m0RqE9MFr2VCMe8eV+yjx8+ScFwd3kCyovsY1lKU=";
  };

  installPhase = ''
    cp -r . $out
  '';
}
