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
  lib,
  ...
}:

let
  optionNames = [
    "optimize"
    "standard"
    "stackSize"
    "pageSize"
    "globalBase"
    "standardIncludes"
    "standardLibraries"
    "freestanding"
    "fastMath"
  ];

  shellNames = {
    optimize = "hull_optimize";
    standard = "hull_standard";
    stackSize = "hull_stack_size";
    pageSize = "hull_page_size";
    globalBase = "hull_global_base";
    standardIncludes = "hull_standard_includes";
    standardLibraries = "hull_standard_libraries";
    freestanding = "hull_freestanding";
    fastMath = "hull_fast_math";
  };

  invalidValue = name: valueExpr: ''
    printf 'Invalid source configuration %s: %s\n' ${lib.escapeShellArg name} ${valueExpr} >&2
    exit 1
  '';

  enumValidator = name: values: valueExpr: ''
    case ${valueExpr} in
      ${lib.concatStringsSep "|" values}) ;;
      *)
        ${invalidValue name valueExpr}
        ;;
    esac
  '';

  unsignedValidator =
    {
      name,
      positive ? false,
      aligned ? null,
    }:
    valueExpr: ''
      case ${valueExpr} in
        ""|*[!0-9]*)
          ${invalidValue name valueExpr}
          ;;
      esac
      if [ ${valueExpr} -gt 4294967295 ]${lib.optionalString positive " || [ ${valueExpr} -eq 0 ]"}${
        lib.optionalString (aligned != null) " || [ $(( ${valueExpr} % ${toString aligned} )) -ne 0 ]"
      }; then
        ${invalidValue name valueExpr}
      fi
    '';

  boolValidator = name: valueExpr: enumValidator name [ "true" "false" ] valueExpr;

  standardValues =
    isCpp:
    let
      versions =
        if isCpp then
          [
            "98"
            "03"
            "11"
            "14"
            "17"
            "20"
            "23"
            "26"
          ]
        else
          [
            "89"
            "99"
            "11"
            "17"
            "23"
          ];
      prefixes =
        if isCpp then
          [
            "c++"
            "gnu++"
          ]
        else
          [
            "c"
            "gnu"
          ];
    in
    lib.concatMap (prefix: map (version: "${prefix}${version}") versions) prefixes;

  defaultOptions = isCpp: {
    optimize = {
      default = _: "3";
      validate = enumValidator "optimize" [
        "0"
        "1"
        "2"
        "3"
        "g"
        "s"
        "z"
      ];
    };
    standard = {
      default = context: context.standard;
      validate = enumValidator "standard" (standardValues isCpp);
    };
    stackSize = {
      default = _: 64 * 1024 * 1024;
      validate = unsignedValidator {
        name = "stackSize";
        positive = true;
        aligned = 16;
      };
    };
    pageSize = {
      default = _: 65536;
      validate = enumValidator "pageSize" [
        "1"
        "65536"
      ];
    };
    globalBase = {
      default = _: 1024;
      validate = unsignedValidator { name = "globalBase"; };
    };
    standardIncludes = {
      default = _: true;
      validate = boolValidator "standardIncludes";
    };
    standardLibraries = {
      default = _: true;
      validate = boolValidator "standardLibraries";
    };
    freestanding = {
      default = _: false;
      validate = boolValidator "freestanding";
    };
    fastMath = {
      default = _: false;
      validate = boolValidator "fastMath";
    };
  };

  validateOverrides =
    overrides:
    let
      unknownOptions = lib.subtractLists optionNames (builtins.attrNames overrides);
      unknownFields = lib.concatMap (
        name:
        map (field: "${name}.${field}") (
          lib.subtractLists [
            "default"
            "validate"
          ] (builtins.attrNames overrides.${name})
        )
      ) (builtins.attrNames overrides);
    in
    if unknownOptions != [ ] then
      throw "Unknown C/C++ options: ${lib.concatStringsSep ", " unknownOptions}"
    else if unknownFields != [ ] then
      throw "Unknown C/C++ option fields: ${lib.concatStringsSep ", " unknownFields}"
    else
      true;

  mergeOptions =
    isCpp: overrides:
    lib.mapAttrs (name: definition: definition // (overrides.${name} or { })) (defaultOptions isCpp);

  valueType =
    name: value:
    if builtins.isString value then
      "string"
    else if builtins.isBool value then
      "bool"
    else if builtins.isInt value then
      "integer"
    else
      throw "Default value for C/C++ option `${name}` must be a string, boolean, or integer";

  shellValue =
    value: if builtins.isBool value then if value then "true" else "false" else toString value;

  quoteShellValue = value: "'${lib.replaceStrings [ "'" ] [ "'\\''" ] value}'";

  resolveOptions =
    definitions: context:
    lib.mapAttrs (
      name: definition:
      let
        value = definition.default context;
      in
      {
        inherit (definition) validate;
        inherit value;
        type = valueType name value;
      }
    ) definitions;

  sourceConfigScript =
    {
      sourceConfigHullPkgs,
      language,
      srcExpr,
      options,
    }:
    let
      initializers = lib.concatMapStringsSep "\n" (
        name: "${shellNames.${name}}=${quoteShellValue (shellValue options.${name}.value)}"
      ) optionNames;
      cases = lib.concatMapStringsSep "\n" (
        name:
        let
          variable = shellNames.${name};
        in
        ''
          ${lib.escapeShellArg name})
            if [ "$type" != ${lib.escapeShellArg options.${name}.type} ]; then
              printf 'Invalid type for source configuration %s: %s\n' "$key" "$type" >&2
              exit 1
            fi
            ${variable}=$value
            ;;
        ''
      ) optionNames;
      validations = lib.concatMapStringsSep "\n" (
        name: options.${name}.validate ("\"$" + shellNames.${name} + "\"")
      ) optionNames;
    in
    ''
      ${initializers}
      hull_source_config_tsv=$(mktemp)
      if ! ${sourceConfigHullPkgs.default}/bin/hull source-config ${lib.escapeShellArg language} < ${srcExpr} > "$hull_source_config_tsv"; then
        rm -f "$hull_source_config_tsv"
        exit 1
      fi
      hull_source_config_tab=$(printf '\t')
      while IFS="$hull_source_config_tab" read -r key type value extra; do
        if [ -n "$extra" ]; then
          printf 'Malformed source configuration record for %s\n' "$key" >&2
          exit 1
        fi
        case "$key" in
          ${cases}
          *)
            printf 'Unknown source configuration key: %s\n' "$key" >&2
            exit 1
            ;;
        esac
      done < "$hull_source_config_tsv"
      rm -f "$hull_source_config_tsv"
      ${validations}
    '';

  mkCFamilyCompileScript =
    {
      hullPkgs,
      isCpp,
      language,
      options,
      sourceConfigHullPkgs,
    }:
    {
      srcExpr,
      outExpr,
      includes,
      extraObjects,
      outputObject,
    }:
    let
      languageFlag = if isCpp then "c++" else "c";
      includeArgs = lib.concatMapStringsSep "\n" (
        path: ''set -- "$@" ${lib.escapeShellArg "-I${path}"}''
      ) includes;
      objectArgs = lib.concatMapStringsSep "\n" (
        path: ''set -- "$@" -x none ${lib.escapeShellArg path}''
      ) extraObjects;
    in
    ''
      ${sourceConfigScript {
        inherit
          language
          options
          sourceConfigHullPkgs
          srcExpr
          ;
      }}
      set -- -x ${lib.escapeShellArg languageFlag} ${srcExpr}
      ${lib.optionalString outputObject ''set -- "$@" -c''}
      set -- "$@" -o ${outExpr}
      ${objectArgs}
      ${includeArgs}
      set -- "$@" "-O$hull_optimize" "-std=$hull_standard"
      ${lib.optionalString (!outputObject) ''
        set -- "$@" -Wl,--strip-debug "-Wl,-z,stack-size=$hull_stack_size" "-Wl,--page-size=$hull_page_size" "-Wl,--global-base=$hull_global_base"
      ''}
      if [ "$hull_standard_includes" = false ]; then
        set -- "$@" -nostdinc
      fi
      if [ "$hull_freestanding" = true ]; then
        set -- "$@" -ffreestanding
      fi
      if [ "$hull_fast_math" = true ]; then
        set -- "$@" -ffast-math
      fi
      ${lib.optionalString (!outputObject) ''
        if [ "$hull_standard_libraries" = true ]; then
          set -- "$@" -lm
          set -- "$@" -lstdc++ -lsupc++
        else
          set -- "$@" -nostdlib
        fi
      ''}
      ${hullPkgs.wasm32-wasi-wasip1.clang}/bin/wasm32-wasi-wasip1-clang++ "$@"
    '';

  compileCFamily =
    {
      pkgs,
      hullPkgs,
      buildHullPkgs,
      isCpp,
      language,
      options,
    }:
    {
      name,
      src,
      includes,
      extraObjects,
      outputObject,
    }:
    let
      namePrefix = if outputObject then "obj" else "wasm";
      extName = if outputObject then "o" else "wasm";
    in
    pkgs.runCommandLocal "hull-${namePrefix}-${name}.${extName}" { } ''
      cp ${src} src.code
      ${
        (mkCFamilyCompileScript {
          inherit
            hullPkgs
            isCpp
            language
            options
            ;
          sourceConfigHullPkgs = buildHullPkgs;
        })
        {
          inherit
            includes
            extraObjects
            outputObject
            ;
          srcExpr = "src.code";
          outExpr = "foo.wasm";
        }
      }
      cp foo.wasm $out
    '';

  mkCFamilyLanguage =
    {
      isCpp,
      language,
      options,
    }:
    {
      compiler =
        {
          pkgs,
          hullPkgs,
          buildHullPkgs,
          ...
        }:
        let
          compilerDrv = compileCFamily {
            inherit
              pkgs
              hullPkgs
              buildHullPkgs
              isCpp
              language
              options
              ;
          };
          compilerScript = mkCFamilyCompileScript {
            inherit
              hullPkgs
              isCpp
              language
              options
              ;
            sourceConfigHullPkgs = hullPkgs;
          };
        in
        {
          object = {
            drv =
              {
                name,
                src,
                includes,
              }:
              compilerDrv {
                inherit name src includes;
                extraObjects = [ ];
                outputObject = true;
              };
            script =
              {
                srcExpr,
                outExpr,
                includes,
              }:
              compilerScript {
                inherit srcExpr outExpr includes;
                extraObjects = [ ];
                outputObject = true;
              };
          };
          executable = {
            drv =
              {
                name,
                src,
                includes,
                extraObjects,
              }:
              compilerDrv {
                inherit
                  name
                  src
                  includes
                  extraObjects
                  ;
                outputObject = false;
              };
            script =
              {
                srcExpr,
                outExpr,
                includes,
                extraObjects,
              }:
              compilerScript {
                inherit
                  srcExpr
                  outExpr
                  includes
                  extraObjects
                  ;
                outputObject = false;
              };
          };
        };
    };

  mkCFamilyLanguages =
    {
      isCpp,
      standards,
    }:
    overrides:
    let
      definitions = mergeOptions isCpp overrides;
      language = if isCpp then "cpp" else "c";
      standardPrefix = if isCpp then "c++" else "c";
    in
    if validateOverrides overrides then
      builtins.listToAttrs (
        map (
          standard:
          let
            languageName = "${language}.${standard}";
            context = {
              inherit language;
              standard = "${standardPrefix}${standard}";
            };
          in
          {
            name = languageName;
            value = mkCFamilyLanguage {
              inherit
                isCpp
                language
                ;
              options = resolveOptions definitions context;
            };
          }
        ) standards
      )
    else
      throw "Invalid C/C++ option definitions";

  c = mkCFamilyLanguages {
    isCpp = false;
    standards = [
      "89"
      "99"
      "11"
      "17"
      "23"
    ];
  };
  cpp = mkCFamilyLanguages {
    isCpp = true;
    standards = [
      "98"
      "03"
      "11"
      "14"
      "17"
      "20"
      "23"
      "26"
    ];
  };
in
{
  inherit c cpp;

  commons = c { } // cpp { };

  matchBaseName =
    baseName: languages:
    let
      languageList = builtins.attrNames languages;
      getAllPrefixes =
        list: if list == [ ] then [ [ ] ] else [ list ] ++ (getAllPrefixes (lib.dropEnd 1 list));
      candidates = map (parts: builtins.concatStringsSep "." parts) (
        getAllPrefixes (lib.reverseList (lib.splitString "." baseName))
      );
      validMatches = builtins.filter (candidate: builtins.elem candidate languageList) candidates;
    in
    if validMatches == [ ] then null else builtins.head validMatches;

  toFileExtension =
    language: builtins.concatStringsSep "." (lib.reverseList (lib.splitString "." language));
}
