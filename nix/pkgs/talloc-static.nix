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

(pkgs.pkgsStatic.talloc.override { python3 = pkgs.buildPackages.python3; }).overrideAttrs (old: {
  buildInputs = [ ];
  # Waf restores dynamic linking after each static library group.
  postPatch = (old.postPatch or "") + ''
    substituteInPlace third_party/waf/waflib/Tools/gcc.py \
      --replace-fail "v.SHLIB_MARKER        = '-Wl,-Bdynamic'" "v.SHLIB_MARKER        = '-Wl,-Bstatic'"
  '';
  wafConfigureFlags = old.wafConfigureFlags ++ [ "--disable-python" ];
  wafBuildFlags = [ "--targets=talloc" ];
  wafInstallFlags = [ "--targets=talloc" ];
  postInstall = old.postInstall + ''
    install -Dm644 talloc.h "$out/include/talloc.h"
    # The static archive also needs the configured replacement functions.
    ${pkgs.pkgsStatic.stdenv.cc.targetPrefix}ar r "$out/lib/libtalloc.a" bin/default/lib/replace/replace.c.*.o
  '';
})
