{
  lib,
  hull,
}:

let
  mkUniqueType =
    typeStr:
    with lib.types;
    addCheck (
      uniq attrs
      // {
        name = typeStr;
        descriptionClass = "noun";
        description = typeStr;
      }
    ) (x: (x._type or null) == typeStr);

  nameStr = lib.types.strMatching "[a-zA-Z_][a-zA-Z0-9_\\-]*";

  programOptions =
    problem:
    { config, ... }:
    {
      src = lib.mkOption {
        type = lib.types.pathInStore;
        description = "Path to the source file.";
      };
      language = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Language of program.";
        readOnly = true;
        default = hull.language.matchBaseName (baseNameOf config.src) problem.languages;
      };
      wasm = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        description = "The compiled WASM artifact.";
        default = hull.compile.wasm problem { inherit (config) src language; };
      };
      cwasm = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        description = "The pre-compiled CWASM artifact.";
        default = hull.compile.cwasm problem {
          srcBaseName = builtins.baseNameOf config.src;
          wasm = config.wasm;
        };
      };
      participantVisibility = lib.mkOption {
        type = lib.types.strMatching "no|src|wasm";
        default = "no";
      };
    };
in
let
  inherit (lib.types)
    submodule
    functionTo
    pathInStore
    nonEmptyStr
    listOf
    attrsOf
    str
    bool
    ints
    attrs
    nullOr
    ;
in
{
  validNameStr = nameStr;

  judger = mkUniqueType "hullJudger";

  language = submodule {
    options = {
      compile = lib.mkOption { type = functionTo pathInStore; };
    };
  };

  testCase =
    problem:
    submodule (
      { name, config, ... }:
      {
        options = {
          name = lib.mkOption {
            type = nameStr;
            readOnly = true;
            default = name;
          };
          generator = lib.mkOption {
            type = nullOr nonEmptyStr;
            default = null;
          };
          generatorCwasm = lib.mkOption {
            type = nullOr pathInStore;
            readOnly = true;
            default =
              let
                generatorName = config.generator;
              in
              if generatorName == null then
                null
              else if builtins.hasAttr generatorName problem.generators then
                problem.generators.${generatorName}.cwasm
              else
                throw "In test case `${config.name}`, generator `${generatorName}` not found";
          };
          arguments = lib.mkOption {
            type = nullOr (listOf str);
            default = null;
          };
          inputFile = lib.mkOption {
            type = nullOr pathInStore;
            default = null;
          };
          traits = lib.mkOption {
            type = attrsOf bool;
            default = { };
          };
          tickLimit = lib.mkOption {
            type = ints.unsigned;
            default = problem.tickLimit;
          };
          memoryLimit = lib.mkOption {
            type = ints.unsigned;
            default = problem.memoryLimit;
          };
          pretest = lib.mkOption {
            type = bool;
            default = false;
          };
          sample = lib.mkOption {
            type = bool;
            default = false;
          };
          data = lib.mkOption {
            type = submodule {
              options = {
                input = lib.mkOption {
                  type = pathInStore;
                  readOnly = true;
                  default =
                    if config.inputFile != null then
                      config.inputFile
                    else if config.generator != null then
                      hull.generate.input problem config
                    else
                      throw "In test case `${config.name}`, `generator` and `inputFile` are both null";
                };
                output = lib.mkOption {
                  type = pathInStore;
                  readOnly = true;
                  default = hull.generate.output problem config;
                };
              };
            };
            readOnly = true;
            default = { };
          };
          inputValidation = lib.mkOption {
            type = attrs;
            readOnly = true;
            default = hull.validate problem config;
          };
        };
      }
    );

  subtask =
    problem:
    submodule (
      { config, ... }:
      {
        options = {
          traits = lib.mkOption {
            type = attrsOf bool;
            default = { };
          };
          testCases = lib.mkOption {
            type = listOf attrs;
            readOnly = true;
            default = builtins.filter (
              tc:
              builtins.all (
                { name, value }:
                builtins.hasAttr name tc.inputValidation.traits && tc.inputValidation.traits.${name} == value
              ) (lib.attrsToList config.traits)
            ) (builtins.attrValues problem.testCases);
          };
        };
      }
    );

  solution =
    problem:
    submodule (args: {
      options = programOptions problem args // {
        mainCorrectSolution = lib.mkOption {
          type = bool;
          default = false;
        };
        subtaskPredictions = lib.mkOption {
          type = attrsOf bool;
          default = { };
        };
      };
    });

  checker =
    problem:
    submodule (args: {
      options = programOptions problem args;
    });

  validator =
    problem:
    submodule (args: {
      options = programOptions problem args;
    });

  generator =
    problem:
    submodule (args: {
      options = programOptions problem args;
    });

  target = mkUniqueType "hullTarget";
}
