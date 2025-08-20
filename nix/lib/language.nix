{ pkgs, hullPkgs }:

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
      includeDirCmd = pkgs.lib.concatMapStringsSep " " (p: "-I${p}") includes;
      extraObjectsCmd = pkgs.lib.concatMapStringsSep " " (p: "-x none ${p}") extraObjects;
      outputFlag = if outputObject then "-c" else "";
      namePrefix = if outputObject then "obj" else "wasm";
      extName = if outputObject then "o" else "wasm";
      linkerFlags =
        if outputObject then "" else "-Wl,--strip-debug -Wl,-z,stack-size=${toString stackSizeInBytes}";
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
      }) (pkgs.lib.genList (i: 8 * (pow 2 i)) 7);
      # 1m, 2m, ..., 512m
      mSizes = map (n: {
        suffix = "s${toString n}m";
        bytes = n * m;
      }) (pkgs.lib.genList (i: pow 2 i) 10);
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

  # Generates language definitions for C/C++ standards.
  makeCFamilyLanguages =
    {
      isCpp,
      standards,
    }:
    let
      langPrefix = if isCpp then "cpp" else "c";
      stdPrefix = if isCpp then "c++" else "c";
    in
    pkgs.lib.foldl (
      acc: std:
      let
        makeLanguage =
          stackSizeInBytes:
          let
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
        # A sized language has a custom stack size.
        makeSizedLang = sizeInfo: {
          name = "${langPrefix}.${std}.${sizeInfo.suffix}";
          value = makeLanguage sizeInfo.bytes;
        };
        defaultLang = {
          "${langPrefix}.${std}" = makeLanguage defaultStackSizeBytes;
        };

        sizedLangs = builtins.listToAttrs (map makeSizedLang stackSizes);
      in
      acc // defaultLang // sizedLangs
    ) { } standards;

  cLanguages = makeCFamilyLanguages {
    isCpp = false;
    standards = cStandards;
  };
  cppLanguages = makeCFamilyLanguages {
    isCpp = true;
    standards = cppStandards;
  };

in
{
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
    let
      inherit (pkgs) lib;
    in
    language: builtins.concatStringsSep "." (lib.reverseList (lib.splitString "." language));
}
