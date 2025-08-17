{
  lib,
  hull,
  config,
  ...
}:

{
  imports = [ ./assertions.nix ];

  options = {
    name = lib.mkOption {
      type = hull.types.nameStr;
      description = "The unique name of the problem, used in derivations and outputs.";
      example = "exampleProblem";
    };

    displayName = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      description = "Display problem title for each language.";
      example = {
        en = "example problem";
        zh = "示例题目";
      };
    };

    includes = lib.mkOption {
      type = lib.types.listOf lib.types.pathInStore;
      default = [ ];
      description = "A list of paths to be added as include directories for compilation.";
    };

    languages = lib.mkOption {
      type = lib.types.attrsOf hull.types.language;
      default = hull.language.commons;
      defaultText = lib.literalExpression "hull.language.commons";
      description = "The attribute set of available programming languages and their compilation logic.";
    };

    judger = lib.mkOption {
      type = hull.types.judger;
      default = hull.batchJudger { };
      defaultText = lib.literalExpression "hull.batchJudger { }";
      description = "The judger implementation to use for evaluating solutions.";
    };

    checker = lib.mkOption {
      type = hull.types.checker config;
      description = "The checker program, which compares a solution's output with the correct answer.";
    };

    validator = lib.mkOption {
      type = hull.types.validator config;
      description = "The validator program, which verifies if a test case's input data is valid.";
    };

    traits = lib.mkOption {
      type = lib.types.attrsOf hull.types.trait;
      default = { };
      description = "An attribute set of all possible traits that can be used to categorize test cases and define subtasks.";
    };

    generators = lib.mkOption {
      type = lib.types.attrsOf (hull.types.generator config);
      default = { };
      description = "An attribute set of generator programs used to create test case inputs.";
    };

    testCases = lib.mkOption {
      type = lib.types.attrsOf (hull.types.testCase config);
      default = { };
      description = "An attribute set defining all test cases for the problem.";
    };

    tickLimit = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = null;
      description = "The default execution time limit in ticks for solutions. Can be overridden per test case.";
    };

    memoryLimit = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = null;
      description = "The default memory limit in bytes for solutions. Can be overridden per test case.";
    };

    subtasks = lib.mkOption {
      type = lib.types.listOf (hull.types.subtask config);
      default = [ ];
      description = "A list of subtasks, where each subtask is defined by a set of required traits.";
    };

    solutions = lib.mkOption {
      type = lib.types.attrsOf (hull.types.solution config);
      default = { };
      description = "An attribute set of solutions for the problem, including correct and incorrect ones.";
    };

    mainCorrectSolution = lib.mkOption {
      type = lib.types.attrs; # Avoid double evaluation
      readOnly = true;
      description = "The single solution marked with `mainCorrectSolution = true`. This is used to generate the official answer files for test cases.";
      default =
        let
          solutions = builtins.attrValues (
            lib.filterAttrs (name: solution: solution.mainCorrectSolution) config.solutions
          );
          count = builtins.length solutions;
        in
        if count == 1 then
          lib.last solutions
        else
          throw "Expected exact 1 solution with `mainCorrectSolution = true`, found ${builtins.toString count}";
      defaultText = "The solution in `config.solutions` for which `mainCorrectSolution` is set to `true`.";
    };

    documents = lib.mkOption {
      type = lib.types.attrsOf hull.types.document;
      default = { };
      description = "An attribute set of documents for the problem.";
    };

    targets = lib.mkOption {
      type = lib.types.attrsOf hull.types.target;
      default = { };
      description = "An attribute set of build targets for the problem, defining final package structures.";
    };

    targetOutputs = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      description = "The final derivation outputs for each defined target.";
      default = builtins.mapAttrs (targetName: target: target config) config.targets;
      defaultText = lib.literalExpression "builtins.mapAttrs (targetName: target: target config) config.targets";
    };
  };
}
