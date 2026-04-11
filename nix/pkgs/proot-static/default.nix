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
  talloc-static,
}:

let
  static = pkgs.pkgsStatic;
in
static.stdenv.mkDerivation {
  pname = "proot-static";
  version = "5.4.0";

  src = pkgs.fetchFromGitHub {
    owner = "proot-me";
    repo = "proot";
    rev = "v5.4.0";
    hash = "sha256-Z9Y7ccWp5KEVuo9xfHcgo58XqYVdFo7ck1jH7cnT2KA=";
  };

  nativeBuildInputs = [
    static.pkg-config
  ];

  buildInputs = [
    static.ncurses
    talloc-static
  ];

  postPatch = ''
    substituteInPlace src/GNUmakefile \
      --replace /bin/echo ${static.coreutils}/bin/echo \
      --replace 'HAS_SWIG := $(shell swig -version 2>/dev/null)' 'HAS_SWIG :=' \
      --replace 'HAS_PYTHON_CONFIG := $(shell ''${PYTHON}-config --ldflags ''${PYTHON_EMBED} 2>/dev/null)' 'HAS_PYTHON_CONFIG :='
    sed -i /CROSS_COMPILE/d src/GNUmakefile
    grep -q '<libgen.h>' src/cli/cli.c || sed -i '/#include <string.h>/a #include <libgen.h>' src/cli/cli.c
  '';

  buildPhase = ''
    make -C src \
      CC="$CC" \
      LD="$CC" \
      CFLAGS="-D_GNU_SOURCE -O3 -static" \
      LDFLAGS="-static -L${talloc-static}/lib -ltalloc"
  '';

  installPhase = ''
    mkdir -p "$out/bin"
    cp src/proot "$out/bin/proot"
  '';

  meta.platforms = pkgs.lib.platforms.linux;
}
