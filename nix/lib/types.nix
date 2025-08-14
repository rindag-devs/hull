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

  runReportSubmodule = lib.types.submodule {
    options = {
      status = lib.mkOption {
        type = lib.types.strMatching "internal_error|accepted|runtime_error|time_limit_exceeded|memory_limit_exceeded";
        description = "The execution status of the run.";
      };
      tick = lib.mkOption {
        type = lib.types.ints.unsigned;
        description = "The number of ticks consumed during execution.";
      };
      memory = lib.mkOption {
        type = lib.types.ints.unsigned;
        description = "The peak memory usage in bytes.";
      };
      exit_code = lib.mkOption {
        type = lib.types.ints.s32;
        description = "The exit code of the program.";
      };
      error_message = lib.mkOption {
        type = lib.types.str;
        description = "Any error message produced by the runtime.";
      };
    };
  };

  runResultSubmodule = lib.types.submodule {
    options = {
      stdout = lib.mkOption {
        type = lib.types.pathInStore;
        description = "A store path to the program's standard output.";
      };
      stderr = lib.mkOption {
        type = lib.types.pathInStore;
        description = "A store path to the program's standard error.";
      };
      report = lib.mkOption {
        type = runReportSubmodule;
        description = "A structured report of the execution result.";
      };
    };
  };

  checkReportSubmodule = lib.types.submodule {
    options = {
      status = lib.mkOption {
        type = lib.types.strMatching "internal_error|accepted|wrong_answer|partially_correct";
        description = "The result of the check.";
      };
      score = lib.mkOption {
        type = lib.types.numbers.between 0 1;
        description = "The score awarded by the checker (typically between 0.0 and 1.0).";
      };
      message = lib.mkOption {
        type = lib.types.str;
        description = "A message from the checker explaining the result.";
      };
      reader_trace_stacks = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
        description = "Internal trace information from the checker's input readers.";
      };
      evaluator_trace_stacks = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
        description = "Internal trace information from the checker's evaluator.";
      };
    };
  };

  testCaseResultSubmodule = lib.types.submodule {
    options = {
      run = lib.mkOption {
        type = runResultSubmodule;
        description = "The result of running the solution against a test case input.";
      };
      check = lib.mkOption {
        type = lib.types.nullOr checkReportSubmodule;
        description = "The result of checking the solution's output against the correct answer.";
      };
      status = lib.mkOption {
        type = lib.types.strMatching "internal_error|accepted|wrong_answer|partially_correct|runtime_error|time_limit_exceeded|memory_limit_exceeded";
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
        default = hull.compile.wasm problem { inherit (config) src language; };
        defaultText = lib.literalExpression "hull.compile.wasm problem { inherit (config) src language; }";
      };
      cwasm = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        description = "The pre-compiled (AOT) CWASM artifact of the program.";
        default = hull.compile.cwasm problem {
          srcBaseName = builtins.baseNameOf config.src;
          wasm = config.wasm;
        };
        defaultText = lib.literalExpression ''
          hull.compile.cwasm problem {
            srcBaseName = builtins.baseNameOf config.src;
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
    strMatching
    ;
in
{

  inherit
    nameStr
    runReportSubmodule
    runResultSubmodule
    checkReportSubmodule
    testCaseResultSubmodule
    ;

  judger = mkUniqueType "hullJudger";

  language = submodule {
    options = {
      compile = lib.mkOption {
        type = functionTo pathInStore;
        description = "The function used to compile a source file of this language.";
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
          pretest = lib.mkOption {
            type = bool;
            default = false;
            description = "Whether this test case should be included in the pretest set.";
          };
          sample = lib.mkOption {
            type = bool;
            default = false;
            description = "Whether this test case is a sample case (e.g., visible in the problem statement).";
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
                output = lib.mkOption {
                  type = pathInStore;
                  readOnly = true;
                  description = "The store path to the correct output data file, generated by running the `mainCorrectSolution`.";
                  default = hull.generate.output problem config;
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
                reader_trace_stacks = lib.mkOption {
                  type = listOf attrs;
                  default = [ ];
                  description = "Internal trace information from the validator's input readers.";
                };
                reader_trace_tree = lib.mkOption {
                  type = listOf attrs;
                  default = [ ];
                  description = "Internal trace tree from the validator.";
                };
                traits = lib.mkOption {
                  type = attrsOf bool;
                  default = { };
                  description = "The set of traits automatically detected by the validator from the input data.";
                };
              };
            };
            readOnly = true;
            description = "The result of running the validator on the test case's input data.";
            default = hull.validate problem config;
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
            type = numbers.nonnegative;
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
      { config, name, ... }@args:
      {
        options = programOptions problem args // {
          name = lib.mkOption {
            type = nameStr;
            readOnly = true;
            default = name;
            description = "The name of the solution, derived from its attribute name in the `solutions` set.";
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
              A prediction for each subtask, expressed as a function that takes the raw score (0.0-1.0)
              and returns true if the prediction is met.'';
            example = lib.literalExpression ''{ "0" = score: score == 1; "1" = score: score >= 0.5; }'';
          };
          testCaseResults = lib.mkOption {
            type = attrsOf testCaseResultSubmodule;
            readOnly = true;
            description = "The collected results of running and checking this solution against all test cases.";
            default = builtins.listToAttrs (
              map (tc: {
                name = tc.name;
                value =
                  let
                    run = hull.judge.run problem tc config;
                    check = if run.report.status == "accepted" then hull.judge.check problem tc config else null;
                    status = if check != null then check.status else run.report.status;
                    score = if check != null then check.score else 0.0;
                    message = if check != null then check.message else run.report.error_message;
                  in
                  {
                    inherit
                      run
                      check
                      status
                      score
                      message
                      ;
                  };
              }) (builtins.attrValues problem.testCases)
            );
            defaultText = "Computed by running and checking the solution against every test case in `problem.testCases`.";
          };
          subtaskResults = lib.mkOption {
            type = listOf (submodule {
              options = {
                testCases = lib.mkOption {
                  type = attrsOf testCaseResultSubmodule;
                  description = "The results of test cases in this subtask.";
                };
                rawScore = lib.mkOption {
                  type = numbers.between 0 1;
                  description = "The lowest score of all test cases in this subtask, with a maximum score of 1.";
                };
                scaledScore = lib.mkOption {
                  type = numbers.nonnegative;
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
                rawScore = builtins.foldl' lib.min 1.0 (map (tc: tc.score) (builtins.attrValues testCases));
                scaledScore = rawScore * st.fullScore;
              in
              {
                inherit testCases rawScore scaledScore;
              }
            ) problem.subtasks;
            defaultText = "Computed by running and checking the solution against every test case in `problem.subtask.{name}.testCases";
          };
          score = lib.mkOption {
            type = numbers.nonnegative;
            readOnly = true;
            description = "This final score of the entire problem for this solution.";
            default = builtins.foldl' builtins.add 0 (
              map (builtins.getAttr "scaledScore") config.subtaskResults
            );
            defaultText = lib.literalExpression ''
              builtins.foldl' builtins.add 0 (
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

  target = mkUniqueType "hullTarget";
}
