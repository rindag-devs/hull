{ pkgs, hullPkgs }:

{
  commons =
    let
      compileCFamily =
        {
          name,
          src,
          isCpp,
          std,
          includes,
        }:
        let
          compiler = if isCpp then "clang++" else "clang";
          language = if isCpp then "c++" else "c";
          includeDirCmd = pkgs.lib.concatMapStringsSep " " (p: "-I${p}") includes;
        in
        pkgs.runCommandLocal name
          {
            nativeBuildInputs = [ hullPkgs.wasm-judge-clang ];
          }
          ''
            cp ${src} foo.code
            wasm-judge-${compiler} -x${language} foo.code -o foo.wasm ${includeDirCmd} -O3 -std=${std} -Wl,--strip-debug -Wl,-z,stack-size=8388608
            cp foo.wasm $out
          '';

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

      cLanguages = builtins.listToAttrs (
        map (std: {
          name = "c.${std}";
          value = {
            compile =
              {
                name,
                src,
                includes,
              }:
              compileCFamily {
                inherit name src includes;
                isCpp = false;
                std = "c${std}";
              };
          };
        }) cStandards
      );

      cppLanguages = builtins.listToAttrs (
        map (std: {
          name = "cpp.${std}";
          value = {
            compile =
              {
                name,
                src,
                includes,
              }:
              compileCFamily {
                inherit name src includes;
                isCpp = true;
                std = "c++${std}";
              };
          };
        }) cppStandards
      );
    in
    cLanguages // cppLanguages;

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
    let
      inherit (pkgs) lib;
    in
    language: builtins.concatStringsSep "." (lib.reverseList (lib.splitString "." language));
}
