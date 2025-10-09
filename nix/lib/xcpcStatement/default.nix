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
  hull,
  lib,
  pkgs,
  ...
}:

problem:
{
  # Path of statement typst file.
  statement,

  # The display language of the statement.
  displayLanguage,

  # Extra translation .typ files for statement.
  # A map from display language to file path.
  extraTranslations ? { },

  # Extra typst packages for building statement.
  extraTypstPackages ? [ ],

  # Extra font paths for building statement.
  extraFontPaths ? [ ],
}:

let
  statementSrc = pkgs.runCommandLocal "hull-xcpcStatement-${problem.name}" { } ''
    mkdir $out
    cp ${./statement/main.typ} $out/main.typ
    cp -r ${./statement/translation} $out/translation
    ${lib.concatMapAttrsStringSep "\n" (
      displayLanguage: path: "cp -f ${path} $out/translation/${displayLanguage}.typ"
    ) extraTranslations}
    install -Dm644 ${statement} $out/problem/${displayLanguage}.typ
  '';
in
hull.document.mkProblemTypstDocument problem {
  src = statementSrc;
  inputs = {
    language = displayLanguage;
  };
  typstPackages = [
    {
      name = "titleize";
      version = "0.1.1";
      hash = "sha256-Z0okd0uGhUDpdLXWpS+GvKVk1LSs15CE7l0l7kZqWLo=";
    }
    {
      name = "tablex";
      version = "0.0.9";
      hash = "sha256-yzg4LKpT1xfVUR5JyluDQy87zi2sU5GM27mThARx7ok=";
    }
    {
      name = "diagraph";
      version = "0.3.6";
      hash = "sha256-U/KxwlNyCIFHyMJKkjeQ4NDCYZhqNgM+oxJZ8Lov3nA=";
    }
  ]
  ++ extraTypstPackages;
  fontPaths = [
    "${pkgs.source-han-serif}/share/fonts/opentype/source-han-serif"
  ]
  ++ extraFontPaths;
}
