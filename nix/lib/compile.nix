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
  hullPkgs,
  hull,
  ...
}:

let
  getLangInfo =
    src: languages:
    let
      languageName = hull.language.matchBaseName (baseNameOf src) languages;
      language = languages.${languageName};
    in
    {
      inherit languageName language;
    };
in
{
  # Compiles a source file to a WASM object file.
  object =
    {
      languages,
      name,
      src,
      includes,
    }:
    let
      langInfo = getLangInfo src languages;
    in
    langInfo.language.compile.object {
      inherit name src includes;
    };

  # Compiles a source file to a WASM executable file.
  executable =
    {
      languages,
      name,
      src,
      includes,
      extraObjects,
    }:
    let
      langInfo = getLangInfo src languages;
    in
    langInfo.language.compile.executable {
      inherit
        name
        src
        includes
        extraObjects
        ;
    };

  # Compiles a WASM file to a native CWASM artifact for faster execution.
  cwasm =
    { name, wasm }:
    pkgs.runCommandLocal "hull-cwasm-${name}.cwasm"
      {
        nativeBuildInputs = [ hullPkgs.default ];
      }
      ''
        hull compile-cwasm ${wasm} $out
      '';
}
