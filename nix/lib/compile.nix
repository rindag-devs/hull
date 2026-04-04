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

  sortLanguageNamesBySpecificity =
    languages:
    builtins.sort (
      a: b:
      let
        aExt = hull.language.toFileExtension a;
        bExt = hull.language.toFileExtension b;
      in
      if builtins.stringLength aExt == builtins.stringLength bExt then
        a < b
      else
        builtins.stringLength aExt > builtins.stringLength bExt
    ) (builtins.attrNames languages);

  executableScriptFor =
    {
      languages,
      languageName,
      srcExpr,
      outExpr,
      includes,
      extraObjects,
    }:
    languages.${languageName}.compile.executable.script {
      inherit
        srcExpr
        outExpr
        includes
        extraObjects
        ;
    };

  executableMatchScript =
    {
      languages,
      srcExpr,
      outExpr,
      includes,
      extraObjects,
    }:
    let
      cases = builtins.concatStringsSep "\n" (
        map (
          languageName:
          let
            suffix = hull.language.toFileExtension languageName;
          in
          ''
            *.${suffix})
              ${executableScriptFor {
                inherit
                  languages
                  languageName
                  srcExpr
                  outExpr
                  includes
                  extraObjects
                  ;
              }}
              ;;
          ''
        ) (sortLanguageNamesBySpecificity languages)
      );
    in
    ''
      case "$(basename ${srcExpr})" in
      ${cases}
      *)
        printf 'Unsupported solution language for %s\n' ${srcExpr} >&2
        exit 1
        ;;
      esac
    '';
in
{
  inherit executableMatchScript;

  # Compiles a source file to a WASM object file.
  object = {
    drv =
      {
        languages,
        name,
        src,
        includes,
      }:
      let
        langInfo = getLangInfo src languages;
      in
      langInfo.language.compile.object.drv {
        inherit name src includes;
      };

    script =
      {
        languages,
        src,
        languageName ? null,
        srcExpr,
        outExpr,
        includes,
      }:
      let
        langInfo =
          if languageName == null then
            getLangInfo src languages
          else
            {
              inherit languageName;
              language = languages.${languageName};
            };
      in
      langInfo.language.compile.object.script {
        inherit srcExpr outExpr includes;
      };
  };

  # Compiles a source file to a WASM executable file.
  executable = {
    drv =
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
      langInfo.language.compile.executable.drv {
        inherit
          name
          src
          includes
          extraObjects
          ;
      };

    script =
      {
        languages,
        src,
        languageName ? null,
        srcExpr,
        outExpr,
        includes,
        extraObjects,
      }:
      let
        langInfo =
          if languageName == null then
            getLangInfo src languages
          else
            {
              inherit languageName;
              language = languages.${languageName};
            };
      in
      executableScriptFor {
        inherit
          languages
          srcExpr
          outExpr
          includes
          extraObjects
          ;
        languageName = langInfo.languageName;
      };
  };
}
