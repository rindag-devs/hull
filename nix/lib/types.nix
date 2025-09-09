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
  pkgs,
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
        type = lib.types.listOf lib.types.attrs;
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

  # Type for a single checker test case.
  checkerTest =
    problem:
    lib.types.submodule (
      { config, name, ... }:
      let
        # 1. Determine input file path.
        input =
          if config.inputFile != null then
            config.inputFile
          else if config.generator != null then
            let
              generatorCwasm =
                if builtins.hasAttr config.generator problem.generators then
                  problem.generators.${config.generator}.cwasm
                else
                  throw "In checker test `${name}`, generator `${config.generator}` not found in problem.generators";
            in
            hull.generate.input problem {
              inherit generatorCwasm;
              arguments = config.arguments or [ ];
              name = "${problem.name}-checkerTestInput-${name}";
            }
          else
            throw "Checker test `${name}` must have either inputFile or generator specified.";

        # 2. Determine user output file path.
        output =
          if config.outputFile != null then
            config.outputFile
          else if config.solution != null then
            let
              sol =
                if builtins.hasAttr config.solution problem.solutions then
                  problem.solutions.${config.solution}
                else
                  throw "In checker test `${name}`, solution `${config.solution}` not found in problem.solutions";
              fakeTestCase = {
                name = "checkerTestOutput-${name}";
                inherit (problem) tickLimit memoryLimit;
                data.input = input;
              };
              generatedOutputs = problem.judger.generateOutputs fakeTestCase sol;
            in
            "${generatedOutputs}/${config.outputFile}"
          else
            throw "Checker test `${name}` must have either outputFile or solution specified.";

        # 3. Determine standard answer file path.
        answer =
          let
            fakeTestCase = {
              name = "checkerTestAnswer-${name}";
              data.input = input;
              tickLimit = problem.tickLimit;
              memoryLimit = problem.memoryLimit;
            };
            generatedOutputs = problem.judger.generateOutputs fakeTestCase problem.mainCorrectSolution;
          in
          "${generatedOutputs}/${config.outputName}";

      in
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
          prediction = lib.mkOption {
            type = lib.types.functionTo lib.types.bool;
            description = "A function that takes the check report and returns true if the test passes.";
          };
          resultDrv = lib.mkOption {
            type = lib.types.pathInStore;
            readOnly = true;
            description = "A derivation of the report of running the checker on this test case.";
            default = hull.check.drv {
              name = "${problem.name}-checkerTest-${name}";
              checkerWasm = problem.checker.cwasm;
              inherit input output answer;
            };
            defaultText = "The derivation of the result of running the checker on this test case.";
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
      let
        input =
          if config.inputFile != null then
            config.inputFile
          else if config.generator != null then
            let
              generatorCwasm =
                if builtins.hasAttr config.generator problem.generators then
                  problem.generators.${config.generator}.cwasm
                else
                  throw "In validator test `${name}`, generator `${config.generator}` not found in problem.generators";
            in
            hull.generate.input problem {
              inherit generatorCwasm;
              arguments = config.arguments or [ ];
              name = "validator-test-input-${name}";
            }
          else
            throw "Validator test `${name}` must have either inputFile or generator specified.";
      in
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
          prediction = lib.mkOption {
            type = lib.types.functionTo lib.types.bool;
            description = "A function that takes the validation report and returns true if the test passes.";
          };
          resultDrv = lib.mkOption {
            type = lib.types.pathInStore;
            readOnly = true;
            description = "The derivation of the result of running the validator on this test case.";
            default = hull.validate.drv {
              problemName = problem.name;
              testCaseName = "validatorTest-${name}";
              validatorWasm = problem.validator.cwasm;
              inherit input;
            };
            defaultText = "The result of running the validator on this test case.";
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
                  type = pathInStore;
                  readOnly = true;
                  description = "A nix store path generated by running `mainCorrectSolution`. Each file in this directory is a correct output data file.";
                  default = hull.generate.outputs problem config;
                  defaultText = lib.literalExpression "hull.generate.outputs problem config";
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
            default = problem.testCaseInputValidations.${config.name};
            defaultText = "Running `problem.validator` on this test case produces the result.";
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
            default =
              let
                drvs = lib.mapAttrs (tcName: tc: problem.judger.judge tc config) problem.testCases;
                links = pkgs.linkFarm "hull-testCaseResults-${problem.name}-${config.name}" drvs;
                results = lib.mapAttrs (
                  tcName: _:
                  let
                    outputs = links + "/${tcName}/outputs";
                  in
                  (lib.importJSON (links + "/${tcName}/report.json")) // { inherit outputs; }
                ) drvs;
              in
              results;
            defaultText = "Computed by the problem's configured judger for every test case.";
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
                rawScore =
                  if st.scoringMethod == "min" then
                    builtins.foldl' lib.min 1.0 (map (tc: tc.score) (builtins.attrValues testCases))
                  else if st.scoringMethod == "sum" then
                    (builtins.foldl' builtins.add 0.0 (map (tc: tc.score) (builtins.attrValues testCases)))
                    / (builtins.length (builtins.attrNames testCases))
                  else
                    throw "Invalid subtask scoring method: ${st.scoringMethod}";
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
          default =
            let
              drvs = lib.mapAttrs (_: { resultDrv, ... }: resultDrv) problem.checker.tests;
              results = lib.mapAttrs (_: drv: lib.importJSON drv) drvs;
            in
            results;
          defaultText = "Computed by running the checker on every test case in `problem.checker.tests";
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
          default =
            let
              drvs = lib.mapAttrs (_: { resultDrv, ... }: resultDrv) problem.validator.tests;
              results = lib.mapAttrs (_: drv: lib.importJSON drv) drvs;
            in
            results;
          defaultText = "Computed by running the validator on every test case in `problem.validator.tests";
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
