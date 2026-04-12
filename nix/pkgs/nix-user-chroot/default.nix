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

pkgs.pkgsStatic.stdenv.mkDerivation {
  name = "nix-user-chroot";
  src = ./.;

  buildPhase = ''
    runHook preBuild
    $CC -O3 -static -Wall -Wextra -std=gnu99 -o nix-user-chroot main.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp nix-user-chroot $out/bin/nix-user-chroot
    runHook postInstall
  '';

  meta.platforms = pkgs.lib.platforms.linux;
}
