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
static.stdenv.mkDerivation (finalAttrs: {
  pname = "proot-static";
  version = "5.5.0";

  src = pkgs.fetchFromGitHub {
    owner = "proot-me";
    repo = "proot";
    rev = "v${finalAttrs.version}";
    hash = "sha256-cCsCr6jpvAIYWlxIC2H6nhI5FFI3ApetD/yAaJbDO28=";
  };

  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [ talloc-static ];

  dontConfigure = true;
  enableParallelBuilding = true;
  env.NIX_LDFLAGS = "-static";

  postPatch = ''
    substituteInPlace src/GNUmakefile \
      --replace-fail '/bin/echo' 'echo'
  '';

  makeFlags = [
    "-C"
    "src"
    "CC=${static.stdenv.cc.targetPrefix}cc"
    "LD=${static.stdenv.cc.targetPrefix}cc"
    "LD_CMD=${static.stdenv.cc.targetPrefix}ld"
    "STRIP=${static.stdenv.cc.targetPrefix}strip"
    "OBJCOPY=${static.stdenv.cc.targetPrefix}objcopy"
    "OBJDUMP=${static.stdenv.cc.targetPrefix}objdump"
    "WITHOUT_PYTHON=1"
    "GIT_VERSION=v${finalAttrs.version}"
    "GIT_COMMIT="
    "LDFLAGS=-ltalloc"
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    cp src/proot "$out/bin/proot"
    runHook postInstall
  '';

  meta.platforms = pkgs.lib.platforms.linux;
})
