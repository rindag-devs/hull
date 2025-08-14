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

  runReportSubmodule = lib.types.submodule {
    options = {
      status = lib.mkOption {
        type = lib.types.strMatching "internal_error|accepted|runtime_error|time_limit_exceeded|memory_limit_exceeded";
      };
      tick = lib.mkOption { type = lib.types.ints.unsigned; };
      memory = lib.mkOption { type = lib.types.ints.unsigned; };
      exit_code = lib.mkOption { type = lib.types.ints.s32; };
      error_message = lib.mkOption { type = lib.types.str; };
    };
  };

  runResultSubmodule = lib.types.submodule {
    options = {
      stdout = lib.mkOption { type = lib.types.pathInStore; };
      stderr = lib.mkOption { type = lib.types.pathInStore; };
      report = lib.mkOption { type = runReportSubmodule; };
    };
  };

  checkReportSubmodule = lib.types.submodule {
    options = {
      status = lib.mkOption {
        type = lib.types.strMatching "internal_error|accepted|wrong_answer|partially_correct";
      };
      score = lib.mkOption { type = lib.types.number; };
      message = lib.mkOption { type = lib.types.str; };
      reader_trace_stacks = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
      };
      evaluator_trace_stacks = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
      };
    };
  };

  # Helper function to create a program type that can be coerced from a path.
  # It takes a submodule type and wraps it with coercion logic.
  mkCoercibleProgramType =
    programSubmodule:
    lib.types.coercedTo
      # 1. The target type we want to end up with (the original submodule).
      (lib.types.oneOf [
        lib.types.attrs
        lib.types.pathInStore
      ])
      # 2. The coercion function. If the input is a path, wrap it in { src = ... }.
      #    Otherwise, assume it's already an attribute set and pass it through.
      (val: if lib.isPath val then { src = val; } else val)
      # 3. The type of values we accept as input.
      programSubmodule;
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
    strMatching
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
            type = submodule {
              options = {
                status = lib.mkOption {
                  type = strMatching "internal_error|valid|invalid";
                };
                message = lib.mkOption { type = str; };
                reader_trace_stacks = lib.mkOption {
                  type = listOf attrs;
                  default = [ ];
                };
                reader_trace_tree = lib.mkOption {
                  type = listOf attrs;
                  default = [ ];
                };
                traits = lib.mkOption {
                  type = attrsOf bool;
                  default = { };
                };
              };
            };
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

  inherit runReportSubmodule runResultSubmodule checkReportSubmodule;

  solution =
    problem:
    mkCoercibleProgramType (
      submodule (
        { config, name, ... }@args:
        {
          options = programOptions problem args // {
            name = lib.mkOption {
              type = nameStr;
              readOnly = true;
              default = name;
            };
            mainCorrectSolution = lib.mkOption {
              type = bool;
              default = false;
            };
            subtaskPredictions = lib.mkOption {
              type = attrsOf bool;
              default = { };
            };
            testCaseResults = lib.mkOption {
              type = attrsOf (submodule {
                options = {
                  run = lib.mkOption { type = runResultSubmodule; };
                  check = lib.mkOption { type = nullOr (checkReportSubmodule); };
                };
              });
              readOnly = true;
              default = builtins.listToAttrs (
                map (tc: {
                  name = tc.name;
                  value = {
                    run = hull.judge.run problem tc config;
                    check = hull.judge.check problem tc config;
                  };
                }) (builtins.attrValues problem.testCases)
              );
            };
          };
        }
      )
    );

  checker =
    problem:
    mkCoercibleProgramType (
      submodule (args: {
        options = programOptions problem args;
      })
    );

  validator =
    problem:
    mkCoercibleProgramType (
      submodule (args: {
        options = programOptions problem args;
      })
    );

  generator =
    problem:
    mkCoercibleProgramType (
      submodule (args: {
        options = programOptions problem args;
      })
    );

  target = mkUniqueType "hullTarget";
}
