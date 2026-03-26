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

  testCaseResult = lib.types.submodule {
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
        type = lib.types.pathInStore;
        description = "A nix store path. Each file in this directory is an output data file.";
      };
    };
  };

  programOptions =
    problem:
    { config, ... }:
    {
      src = lib.mkOption {
        type = lib.types.pathInStore;
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
        defaultText = lib.literalExpression "(problem.languages.\${config.language}).compile.executable { ... }";
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

  inputValidationReport = lib.types.submodule {
    options = {
      status = lib.mkOption {
        type = lib.types.strMatching "internal_error|valid|invalid";
        description = "The status of the validation: `valid` or `invalid`.";
      };
      message = lib.mkOption {
        type = lib.types.str;
        description = "A message from the validator.";
      };
      readerTraceStacks = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        description = "Internal trace information from the validator's input readers.";
      };
      readerTraceTree = lib.mkOption {
        type = lib.types.attrs;
        description = "Internal trace tree from the validator.";
      };
      traits = lib.mkOption {
        type = lib.types.attrsOf lib.types.bool;
        description = "The set of traits automatically detected by the validator from the input data.";
      };
    };
  };

  checkReport = lib.types.submodule {
    options = {
      status = lib.mkOption {
        type = lib.types.strMatching "internal_error|accepted|wrong_answer|partially_correct";
        description = "The status of the check.";
      };
      message = lib.mkOption {
        type = lib.types.str;
        description = "A message from the checker.";
      };
      score = lib.mkOption {
        type = lib.types.numbers.between 0 1;
        description = "The score of the check, where the full score is 1.0.";
      };
      readerTraceStacks = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        description = "Internal reader trace information from the checker.";
        default = [ ];
      };
      evaluatorTraceStacks = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        description = "Internal evaluator trace information from the checker.";
        default = [ ];
      };
    };
  };

  coerceStorePath = path: if builtins.isPath path then path else builtins.storePath path;

  # Type for a single checker test case.
  checkerTest =
    problem:
    lib.types.submodule (
      { config, name, ... }:
      {
        options = {
          name = lib.mkOption {
            type = nameStr;
            readOnly = true;
            default = name;
            description = "The name of the test, derived from its attribute name in the `tests` set.";
          };
          generator = lib.mkOption {
            type = lib.types.nullOr lib.types.nonEmptyStr;
            default = null;
            description = "The name of the generator to use for creating the input file.";
          };
          arguments = lib.mkOption {
            type = lib.types.nullOr (lib.types.listOf lib.types.str);
            default = null;
            description = "A list of string arguments to pass to the generator program.";
          };
          inputFile = lib.mkOption {
            type = lib.types.nullOr lib.types.pathInStore;
            default = null;
            description = "A store path to a manually provided input file.";
          };
          solution = lib.mkOption {
            type = lib.types.nullOr lib.types.nonEmptyStr;
            default = null;
            description = "The name of a solution (from `problem.solutions`) to run to get the output file.";
          };
          outputName = lib.mkOption {
            type = lib.types.str;
            default = "output";
            description = "The name of output file, used to select the output name when solution returns multiple outputs.";
          };
          outputFile = lib.mkOption {
            type = lib.types.nullOr lib.types.pathInStore;
            default = null;
            description = "A store path to a manually provided output file.";
          };
          inputPath = lib.mkOption {
            type = lib.types.pathInStore;
            readOnly = true;
            description = "The fully resolved input file used by this checker test.";
            default = coerceStorePath problem.runtimeData.checker.testInputs.${config.name};
          };
          outputPath = lib.mkOption {
            type = lib.types.nullOr lib.types.pathInStore;
            readOnly = true;
            description = "The fully resolved output file when this checker test uses a static output file.";
            default = config.outputFile;
          };
          outputSolution = lib.mkOption {
            type = lib.types.nullOr lib.types.nonEmptyStr;
            readOnly = true;
            description = "The solution name used to generate the output file when `outputFile` is not provided.";
            default = config.solution;
          };
          prediction = lib.mkOption {
            type = lib.types.functionTo lib.types.bool;
            description = "A function that takes the check report and returns true if the test passes.";
          };
          result = lib.mkOption {
            type = checkReport;
            description = "The result of this test.";
            readOnly = true;
            default = problem.checker.testResults.${config.name};
          };
          predictionHolds = lib.mkOption {
            type = lib.types.bool;
            readOnly = true;
            description = "Whether the prediction holds for this test case.";
            default = config.prediction config.result;
            defaultText = "Whether the prediction holds for this test case.";
          };
        };
      }
    );

  # Type for a single validator test case.
  validatorTest =
    problem:
    lib.types.submodule (
      { config, name, ... }:
      {
        options = {
          name = lib.mkOption {
            type = nameStr;
            readOnly = true;
            default = name;
            description = "The name of the test, derived from its attribute name in the `tests` set.";
          };
          generator = lib.mkOption {
            type = lib.types.nullOr lib.types.nonEmptyStr;
            default = null;
            description = "The name of the generator to use for creating the input file.";
          };
          arguments = lib.mkOption {
            type = lib.types.nullOr (lib.types.listOf lib.types.str);
            default = null;
            description = "A list of string arguments to pass to the generator program.";
          };
          inputFile = lib.mkOption {
            type = lib.types.nullOr lib.types.pathInStore;
            default = null;
            description = "A store path to a manually provided input file.";
          };
          inputPath = lib.mkOption {
            type = lib.types.pathInStore;
            readOnly = true;
            description = "The fully resolved input file used by this validator test.";
            default = coerceStorePath problem.runtimeData.validator.testInputs.${config.name};
          };
          prediction = lib.mkOption {
            type = lib.types.functionTo lib.types.bool;
            description = "A function that takes the validation report and returns true if the test passes.";
          };
          result = lib.mkOption {
            type = inputValidationReport;
            description = "The result of this test.";
            readOnly = true;
            default = problem.validator.testResults.${config.name};
          };
          predictionHolds = lib.mkOption {
            type = lib.types.bool;
            readOnly = true;
            description = "Whether the prediction holds for this test case.";
            default = config.prediction config.result;
            defaultText = "Whether the prediction holds for this test case.";
          };
        };
      }
    );
in
let
  inherit (lib.types)
    submodule
    functionTo
    pathInStore
    nonEmptyStr
    strMatching
    listOf
    attrsOf
    str
    bool
    ints
    attrs
    nullOr
    numbers
    float
    ;
in
{

  inherit
    nameStr
    testCaseResultStatusStr
    testCaseResult
    validatorTest
    checkerTest
    inputValidationReport
    checkReport
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
      descriptions = lib.mkOption {
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
          descriptions = lib.mkOption {
            type = attrsOf str;
            description = "The description of this test case for each display language, usually used for samples.";
            default = { };
          };
          data = lib.mkOption {
            type = submodule {
              options = {
                input = lib.mkOption {
                  type = pathInStore;
                  readOnly = true;
                  description = "The store path to the input data file. It's either taken from `inputFile` or generated by `generator`.";
                  default = coerceStorePath problem.runtimeData.testCases.${config.name}.data.input;
                  defaultText = "Loaded from runtime analysis data.";
                };
                outputs = lib.mkOption {
                  type = pathInStore;
                  readOnly = true;
                  description = "A nix store path generated by running `mainCorrectSolution`. Each file in this directory is a correct output data file.";
                  default = coerceStorePath problem.runtimeData.testCases.${config.name}.data.outputs;
                  defaultText = "Loaded from runtime analysis data.";
                };
              };
            };
            readOnly = true;
            default = { };
            description = "Read-only container for the test case's input and output data paths.";
          };
          inputValidation = lib.mkOption {
            type = inputValidationReport;
            readOnly = true;
            description = "The result of running the validator on the test case's input data.";
            default = problem.runtimeData.testCases.${config.name}.inputValidation;
            defaultText = "Loaded from runtime analysis data.";
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
          scoringMethod = lib.mkOption {
            type = strMatching "min|sum";
            description = "Scoring method for this subtask.";
            default = "min";
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
          participantVisibility = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "The visibility of this solution to participants.";
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
            type = attrsOf testCaseResult;
            readOnly = true;
            description = "The collected results of running and checking this solution against all test cases.";
            default = lib.mapAttrs (
              _: result:
              result
              // lib.optionalAttrs (result ? outputs) {
                outputs = coerceStorePath result.outputs;
              }
            ) problem.runtimeData.solutions.${config.name}.testCaseResults;
            defaultText = "Loaded from runtime analysis data.";
          };
          subtaskResults = lib.mkOption {
            type = listOf (submodule {
              options = {
                testCases = lib.mkOption {
                  type = attrsOf testCaseResult;
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
              result:
              result
              // {
                testCases = lib.mapAttrs (
                  _: testCaseResult:
                  testCaseResult
                  // lib.optionalAttrs (testCaseResult ? outputs) {
                    outputs = coerceStorePath testCaseResult.outputs;
                  }
                ) result.testCases;
              }
            ) problem.runtimeData.solutions.${config.name}.subtaskResults;
            defaultText = "Loaded from runtime analysis data.";
          };
          score = lib.mkOption {
            type = float;
            readOnly = true;
            description = "This final score of the entire problem for this solution.";
            default = problem.runtimeData.solutions.${config.name}.score;
            defaultText = "Loaded from runtime analysis data.";
          };
        };
      }
    );

  checker =
    problem:
    submodule (args: {
      options = (programOptions problem args) // {
        tests = lib.mkOption {
          type = attrsOf (checkerTest problem);
          description = "An attribute set of tests for the checker itself.";
          default = { };
        };
        testResults = lib.mkOption {
          type = attrsOf checkReport;
          description = "The result of tests.";
          readOnly = true;
          default = problem.runtimeData.checker.testResults;
          defaultText = "Loaded from runtime analysis data.";
        };
      };
    });

  validator =
    problem:
    submodule (args: {
      options = (programOptions problem args) // {
        tests = lib.mkOption {
          type = attrsOf (validatorTest problem);
          description = "An attribute set of tests for the validator itself.";
          default = { };
        };
        testResults = lib.mkOption {
          type = attrsOf inputValidationReport;
          description = "The result of tests.";
          readOnly = true;
          default = problem.runtimeData.validator.testResults;
          defaultText = "Loaded from runtime analysis data.";
        };
      };
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
      displayLanguage = lib.mkOption {
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

  problemTarget = mkUniqueType "hullProblemTarget";
  contestTarget = mkUniqueType "hullContestTarget";
}
