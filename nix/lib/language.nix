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
  lib,
  ...
}:

let
  # A higher-order function that creates a configured C/C++ compiler for WASM.
  compileCFamily =
    {
      isCpp,
      std,
      stackSizeInBytes,
    }:
    {
      name,
      src,
      includes,
      extraObjects,
      outputObject,
    }:
    let
      languageFlag = if isCpp then "c++" else "c";
      includeDirCmd = lib.concatMapStringsSep " " (p: "-I${p}") includes;
      extraObjectsCmd = lib.concatMapStringsSep " " (p: "-x none ${p}") extraObjects;
      outputFlag = lib.optionalString outputObject "-c";
      namePrefix = if outputObject then "obj" else "wasm";
      extName = if outputObject then "o" else "wasm";
      linkerFlags = lib.optionalString (
        !outputObject
      ) "-Wl,--strip-debug -Wl,-z,stack-size=${toString stackSizeInBytes}";
    in
    pkgs.runCommandLocal "hull-${namePrefix}-${name}.${extName}"
      { nativeBuildInputs = [ hullPkgs.wasm-judge-clang ]; }
      ''
        wasm-judge-clang++ -x ${languageFlag} ${src} ${outputFlag} -o foo.wasm ${extraObjectsCmd} \
          ${includeDirCmd} -O3 -std=${std} ${linkerFlags}
        cp foo.wasm $out
      '';

  k = 1024;
  m = k * 1024;
  g = m * 1024;
  defaultStackSizeBytes = 8 * m;

  pow = base: power: if power != 0 then base * (pow base (power - 1)) else 1;

  stackSizes =
    let
      # 8k, 16k, ..., 512k
      kSizes = map (n: {
        suffix = "s${toString n}k";
        bytes = n * k;
      }) (lib.genList (i: 8 * (pow 2 i)) 7);
      # 1m, 2m, ..., 512m
      mSizes = map (n: {
        suffix = "s${toString n}m";
        bytes = n * m;
      }) (lib.genList (i: pow 2 i) 10);
      # 1G, 2G
      gSizes =
        map
          (n: {
            suffix = "s${toString n}G";
            bytes = n * g;
          })
          [
            1
            2
          ];
    in
    kSizes ++ mSizes ++ gSizes;

  mkCFamilyLanguage =
    {
      isCpp,
      std,
      stackSizeInBytes ? defaultStackSizeBytes,
    }:
    let
      stdPrefix = if isCpp then "c++" else "c";
      compiler = compileCFamily {
        inherit isCpp stackSizeInBytes;
        std = "${stdPrefix}${std}";
      };
    in
    {
      compile.object =
        {
          name,
          src,
          includes,
        }:
        compiler {
          inherit name src includes;
          extraObjects = [ ];
          outputObject = true;
        };
      compile.executable =
        {
          name,
          src,
          includes,
          extraObjects,
        }:
        compiler {
          inherit
            name
            src
            includes
            extraObjects
            ;
          outputObject = false;
        };
    };

  # Generates language definitions for C/C++ standards.
  mkCFamilyLanguages =
    {
      isCpp,
      standards,
    }:
    let
      langPrefix = if isCpp then "cpp" else "c";
    in
    lib.foldl (
      acc: std:
      # A sized language has a custom stack size.
      let
        defaultLang = {
          "${langPrefix}.${std}" = mkCFamilyLanguage { inherit isCpp std; };
        };
        sizedLangs = builtins.listToAttrs (
          map (sizeInfo: {
            name = "${langPrefix}.${std}.${sizeInfo.suffix}";
            value = mkCFamilyLanguage {
              inherit isCpp std;
              stackSizeInBytes = sizeInfo.bytes;
            };
          }) stackSizes
        );
      in
      acc // defaultLang // sizedLangs
    ) { } standards;

  cStandards = [
    "89"
    "99"
    "11"
    "17"
    "23"
  ];
  cppStandards = [
    "98"
    "03"
    "11"
    "14"
    "17"
    "20"
    "23"
    "26"
  ];

  cLanguages = mkCFamilyLanguages {
    isCpp = false;
    standards = cStandards;
  };
  cppLanguages = mkCFamilyLanguages {
    isCpp = true;
    standards = cppStandards;
  };

in
{
  inherit cLanguages cppLanguages;

  commons = cLanguages // cppLanguages;

  matchBaseName =
    baseName: languages:
    let
      inherit (pkgs) lib;
      languageList = builtins.attrNames languages;

      getAllPrefixes =
        list: if list == [ ] then [ [ ] ] else [ list ] ++ (getAllPrefixes (lib.dropEnd 1 list));

      candidates = map (l: builtins.concatStringsSep "." l) (
        getAllPrefixes (lib.reverseList (lib.splitString "." baseName))
      );

      validMatches = builtins.filter (candidate: builtins.elem candidate languageList) candidates;
    in
    if validMatches == [ ] then
      throw "Cannot find a matched language for `${baseName}`"
    else
      lib.last validMatches;

  toFileExtension =
    language: builtins.concatStringsSep "." (lib.reverseList (lib.splitString "." language));
}
