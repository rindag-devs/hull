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

{ pkgs }:

let
  static = pkgs.pkgsStatic;
in
static.stdenv.mkDerivation {
  pname = "talloc-static-minimal";
  version = "2.4.3";

  src = pkgs.fetchurl {
    url = "https://www.samba.org/ftp/talloc/talloc-2.4.3.tar.gz";
    hash = "sha256-3EbEC59GuzTdl/5B9Uiw6LJHt3qRhXZzPFKOg6vYVN0=";
  };

  dontConfigure = true;

  postPatch = ''
    mkdir -p fake-include
    : > fake-include/standards.h
    cp ${./fake-replace.h} fake-include/replace.h
    cp ${./fake-config.h} config.h
    grep -q "config.h" talloc.c || sed -i '/#include "replace\.h"/i #include "config.h"' talloc.c
  '';

  buildPhase = ''
    mkdir -p build
    $CC -O3 -static -include stdbool.h -include string.h -I. -Ifake-include -c talloc.c -o build/talloc.o
    $AR rcs build/libtalloc.a build/talloc.o
  '';

  installPhase = ''
    mkdir -p $out/lib $out/include
    cp build/libtalloc.a $out/lib/
    cp talloc.h $out/include/
  '';

  meta.platforms = pkgs.lib.platforms.linux;
}
