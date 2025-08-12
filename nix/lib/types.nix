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

  plusMinusStr = lib.types.strMatching "[+-][^\n\r]+";
  validNameStr = lib.types.strMatching "[a-zA-Z_][a-zA-Z0-9_\\-]*";

  programOptions =
    with lib.types;
    problem: args: {
      src = lib.mkOption {
        type = pathInStore;
        description = "Path to the source file.";
      };
      language = lib.mkOption {
        type = nonEmptyStr;
        description = "Language of program.";
        readOnly = true;
        default = hull.language.matchBaseName (baseNameOf args.config.src) problem.languages;
      };
      wasm = lib.mkOption {
        type = package;
        readOnly = true;
        description = "The compiled WASM artifact.";
        default = hull.compile.wasm problem { inherit (args.config) src language; };
      };
      cwasm = lib.mkOption {
        type = package;
        readOnly = true;
        description = "The pre-compiled CWASM artifact.";
        default = hull.compile.cwasm {
          name = builtins.baseNameOf args.config.src;
          wasm = args.config.wasm;
        };
      };
      participantVisibility = lib.mkOption {
        type = strMatching "no|src|wasm";
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
    str
    bool
    ints
    attrs
    ;
in
{
  inherit plusMinusStr validNameStr;

  judger = mkUniqueType "hullJudger";

  language = submodule {
    options = {
      compile = lib.mkOption { type = functionTo pathInStore; };
    };
  };

  testCase =
    problem:
    submodule (args: {
      options = {
        generator = lib.mkOption { type = nonEmptyStr; };
        generatorCwasm = lib.mkOption {
          type = pathInStore;
          readOnly = true;
          default =
            let
              generatorName = args.config.generator;
            in
            if builtins.hasAttr generatorName problem.generators then
              problem.generators."${generatorName}".cwasm
            else
              throw "Generator `${generatorName}` not found";
        };
        arguments = lib.mkOption { type = listOf str; };
        traits = lib.mkOption { type = listOf plusMinusStr; };
        hash = lib.mkOption { type = str; };
        pretest = lib.mkOption {
          type = bool;
          default = false;
        };
        sample = lib.mkOption {
          type = bool;
          default = false;
        };
        data = lib.mkOption {
          type = attrs;
          readOnly = true;
          default = hull.generate.data problem args.config;
        };
      };
    });

  subtask =
    problem:
    submodule {
      options = {
        traits = lib.mkOption {
          type = listOf plusMinusStr;
          default = [ ];
        };
        tickLimit = lib.mkOption {
          type = ints.unsigned;
          default = problem.tickLimit;
        };
        memoryLimit = lib.mkOption {
          type = ints.unsigned;
          default = problem.memoryLimit;
        };
      };
    };

  solution =
    problem:
    submodule (args: {
      options = programOptions problem args // {
        mainCorrectSolution = lib.mkOption {
          type = bool;
          default = false;
        };
        subtaskPredictions = lib.mkOption {
          type = listOf plusMinusStr;
          default = [ ];
        };
      };
    });

  checker =
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
