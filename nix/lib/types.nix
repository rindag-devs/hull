{
  lib,
  hull,
  ...
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

  testCaseResultStatusStr = lib.types.strMatching "internal_error|accepted|wrong_answer|partially_correct|runtime_error|time_limit_exceeded|memory_limit_exceeded";

  testCaseResultSubmodule = lib.types.submodule {
    options = {
      status = lib.mkOption {
        type = testCaseResultStatusStr;
        description = "The status of judgement.";
      };
      score = lib.mkOption {
        type = lib.types.numbers.between 0 1;
        description = "The score of judgement, with a maximum score of 1.";
      };
      message = lib.mkOption {
        type = lib.types.str;
        description = "The message of judgement.";
      };
      tick = lib.mkOption {
        type = lib.types.ints.unsigned;
        description = "The WASM tick of judgement.";
      };
      memory = lib.mkOption {
        type = lib.types.ints.unsigned;
        description = "The memory in bytes of judgement.";
      };
      outputs = lib.mkOption {
        type = lib.types.attrsOf lib.types.pathInStore;
        description = "The output files of judgement";
      };
    };
  };

  programOptions =
    problem:
    { config, ... }:
    {
      src = lib.mkOption {
        type = lib.types.path;
        description = "Path to the source file of the program.";
      };
      language = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "The programming language of the source file. It is automatically detected from the file extension.";
        readOnly = true;
        default = hull.language.matchBaseName (baseNameOf config.src) problem.languages;
        defaultText = lib.literalExpression "hull.language.matchBaseName (baseNameOf config.src) problem.languages";
      };
      wasm = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        description = "The compiled WASM artifact of the program.";
        default =
          let
            lang = problem.languages.${config.language};
          in
          lang.compile.executable {
            name = "${problem.name}-program-${builtins.baseNameOf config.src}";
            inherit (config) src;
            includes = problem.includes;
            extraObjects = [ ];
          };
        defaultText = lib.literalExpression ''(problem.languages.''${config.language}).compile.executable { ... }'';
      };
      cwasm = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        description = "The pre-compiled (AOT) CWASM artifact of the program.";
        default = hull.compile.cwasm {
          name = "${problem.name}-program-${builtins.baseNameOf config.src}";
          wasm = config.wasm;
        };
        defaultText = lib.literalExpression ''
          hull.compile.cwasm {
            name = ...;
            wasm = config.wasm;
          }'';
      };
      participantVisibility = lib.mkOption {
        type = lib.types.strMatching "no|src|wasm";
        default = "no";
        description = ''
          Controls the visibility of this program to participants.
          - `no`: Not visible.
          - `src`: Source code is visible.
          - `wasm`: Compiled WASM is visible.'';
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
    numbers
    float
    strMatching
    ;
in
{

  inherit
    nameStr
    testCaseResultStatusStr
    testCaseResultSubmodule
    ;

  judger = mkUniqueType "hullJudger";

  language = submodule {
    options = {
      compile = lib.mkOption {
        type = submodule {
          options = {
            object = lib.mkOption {
              type = functionTo pathInStore;
              description = "The function used to compile a source file into a linkable object file.";
            };
            executable = lib.mkOption {
              type = functionTo pathInStore;
              description = "The function used to link a source file and object files into an executable.";
            };
          };
        };
        description = "Compile functions.";
      };
    };
  };

  trait = submodule {
    options = {
      description = lib.mkOption {
        type = attrsOf str;
        description = "The description of this trait for each display language.";
        example = {
          en = "$a$ is a positive integer.";
          zh = "$a$ 为正整数";
        };
        default = { };
      };
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
            description = "The name of the test case, derived from its attribute name in the `testCases` set.";
          };
          generator = lib.mkOption {
            type = nullOr nonEmptyStr;
            default = null;
            description = "The name of the generator (from the top-level `generators` set) to use for creating the input file. If set, `inputFile` should be null.";
          };
          generatorCwasm = lib.mkOption {
            type = nullOr pathInStore;
            readOnly = true;
            description = "The store path to the compiled CWASM of the specified generator.";
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
            defaultText = "The `.cwasm` attribute of the corresponding generator in `problem.generators`.";
          };
          arguments = lib.mkOption {
            type = nullOr (listOf str);
            default = null;
            description = "A list of string arguments to pass to the generator program.";
          };
          inputFile = lib.mkOption {
            type = nullOr pathInStore;
            default = null;
            description = "A store path to a manually provided input file. If set, `generator` should be null.";
          };
          traits = lib.mkOption {
            type = attrsOf bool;
            default = { };
            description = "An attribute set of traits that this test case possesses. Must match the traits output by the validator.";
          };
          tickLimit = lib.mkOption {
            type = ints.unsigned;
            default = problem.tickLimit;
            defaultText = lib.literalExpression "problem.tickLimit";
            description = "Execution time limit in ticks for this specific test case.";
          };
          memoryLimit = lib.mkOption {
            type = ints.unsigned;
            default = problem.memoryLimit;
            defaultText = lib.literalExpression "problem.memoryLimit";
            description = "Memory limit in bytes for this specific test case.";
          };
          groups = lib.mkOption {
            type = listOf nameStr;
            default = [ ];
            description = "The groups to which this test case belongs.";
            example = [
              "sample"
              "pretest"
            ];
          };
          data = lib.mkOption {
            type = submodule {
              options = {
                input = lib.mkOption {
                  type = pathInStore;
                  readOnly = true;
                  description = "The store path to the input data file. It's either taken from `inputFile` or generated by `generator`.";
                  default =
                    if config.inputFile != null then
                      config.inputFile
                    else if config.generator != null then
                      hull.generate.input problem config
                    else
                      throw "In test case `${config.name}`, `generator` and `inputFile` are both null";
                  defaultText = "Derived from `inputFile` or `generator`.";
                };
                outputs = lib.mkOption {
                  type = attrsOf pathInStore;
                  readOnly = true;
                  description = "The store path to the correct output data file, generated by running the `mainCorrectSolution`.";
                  default = hull.generate.outputs problem config;
                  defaultText = lib.literalExpression "hull.generate.output problem config";
                };
              };
            };
            readOnly = true;
            default = { };
            description = "Read-only container for the test case's input and output data paths.";
          };
          inputValidation = lib.mkOption {
            type = submodule {
              options = {
                status = lib.mkOption {
                  type = strMatching "internal_error|valid|invalid";
                  description = "The status of the validation: `valid` or `invalid`.";
                };
                message = lib.mkOption {
                  type = str;
                  description = "A message from the validator.";
                };
                readerTraceStacks = lib.mkOption {
                  type = listOf attrs;
                  description = "Internal trace information from the validator's input readers.";
                };
                readerTraceTree = lib.mkOption {
                  type = listOf attrs;
                  description = "Internal trace tree from the validator.";
                };
                traits = lib.mkOption {
                  type = attrsOf bool;
                  description = "The set of traits automatically detected by the validator from the input data.";
                };
              };
            };
            readOnly = true;
            description = "The result of running the validator on the test case's input data.";
            default = hull.validate {
              problemName = problem.name;
              testCaseName = config.name;
              validatorWasm = problem.validator.cwasm;
              input = config.data.input;
            };
            defaultText = lib.literalExpression "hull.validate problem config";
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
            description = "An attribute set of traits that a test case must have to belong to this subtask.";
          };
          fullScore = lib.mkOption {
            type = float;
            description = "The full score of this subtask.";
          };
          testCases = lib.mkOption {
            type = listOf attrs;
            readOnly = true;
            description = "A list of test cases that match the traits defined for this subtask.";
            default = builtins.filter (
              tc:
              builtins.all (
                { name, value }:
                builtins.hasAttr name tc.inputValidation.traits && tc.inputValidation.traits.${name} == value
              ) (lib.attrsToList config.traits)
            ) (builtins.attrValues problem.testCases);
            defaultText = "A filtered list of `problem.testCases` matching the subtask's traits.";
          };
        };
      }
    );

  solution =
    problem:
    submodule (
      { config, name, ... }:
      {
        options = {
          name = lib.mkOption {
            type = nameStr;
            readOnly = true;
            default = name;
            description = "The name of the solution, derived from its attribute name in the `solutions` set.";
          };
          src = lib.mkOption {
            type = lib.types.path;
            description = "Path to the source file or directory of the solution.";
          };
          mainCorrectSolution = lib.mkOption {
            type = bool;
            default = false;
            description = "Whether this solution is the main correct one, used to generate answer files. Exactly one solution must have this set to `true`.";
          };
          subtaskPredictions = lib.mkOption {
            type = attrsOf (functionTo bool);
            default = { };
            description = ''
              A prediction for each subtask, expressed as a function that takes an attributes set of raw score (0.0-1.0)
              and statuses, and then returns true if the prediction is met.'';
            example = lib.literalExpression ''
              {
                "0" = { score, ... }: score >= 0.5;
                "1" = { statuses, ... }: builtins.all (s: s == "accepted" || s == "time_limit_exceeded") statuses;
              }'';
          };
          testCaseResults = lib.mkOption {
            type = attrsOf testCaseResultSubmodule;
            readOnly = true;
            description = "The collected results of running and checking this solution against all test cases.";
            default = lib.mapAttrs (tcName: tc: problem.judger.judge tc config) problem.testCases;
            defaultText = "Computed by the problem's configured judger for every test case.";
          };
          subtaskResults = lib.mkOption {
            type = listOf (submodule {
              options = {
                testCases = lib.mkOption {
                  type = attrsOf testCaseResultSubmodule;
                  description = "The results of test cases in this subtask.";
                };
                statuses = lib.mkOption {
                  type = listOf testCaseResultStatusStr;
                  description = "The result status of all test cases in this subtask. Already sorted and deduplicated.";
                };
                rawScore = lib.mkOption {
                  type = numbers.between 0 1;
                  description = "The lowest score of all test cases in this subtask, with a maximum score of 1.";
                };
                scaledScore = lib.mkOption {
                  type = float;
                  description =
                    "The lowest score of all test cases in this subtask, "
                    + "with a maximum score of `fullScore` defined in subtask options.";
                };
              };
            });
            readOnly = true;
            description = "The collected results of this solution against all subtasks.";
            default = map (
              st:
              let
                testCases = builtins.listToAttrs (
                  map (tc: {
                    name = tc.name;
                    value = config.testCaseResults.${tc.name};
                  }) st.testCases
                );
                statuses = lib.unique (
                  builtins.sort builtins.lessThan (lib.map ({ status, ... }: status) (builtins.attrValues testCases))
                );
                rawScore = builtins.foldl' lib.min 1.0 (map (tc: tc.score) (builtins.attrValues testCases));
                scaledScore = rawScore * st.fullScore;
              in
              {
                inherit
                  testCases
                  statuses
                  rawScore
                  scaledScore
                  ;
              }
            ) problem.subtasks;
            defaultText = "Computed by running and checking the solution against every test case in `problem.subtask.{name}.testCases";
          };
          score = lib.mkOption {
            type = float;
            readOnly = true;
            description = "This final score of the entire problem for this solution.";
            default = builtins.foldl' builtins.add 0.0 (
              map ({ scaledScore, ... }: scaledScore) config.subtaskResults
            );
            defaultText = lib.literalExpression ''
              builtins.foldl' builtins.add 0.0 (
                lib.mapAttrs (stName: st: st.score) config.subtaskResults
              )'';
          };
        };
      }
    );

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

  document = submodule {
    options = {
      path = lib.mkOption {
        type = pathInStore;
        description = "The path of this document.";
      };
      language = lib.mkOption {
        type = str;
        description = "The display language of this document.";
        example = "en";
      };
      participantVisibility = lib.mkOption {
        type = bool;
        default = false;
        description = "The visibility of this document to participants.";
      };
    };
  };

  target = mkUniqueType "hullTarget";
}
