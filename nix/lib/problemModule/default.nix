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
  config,
  pkgs,
  ...
}:

{
  imports = [ ./assertions.nix ];

  options = {
    problemAttrs = lib.mkOption {
      type = lib.types.raw;
      description = "User problem configuration passed in when evalProblem.";
      readOnly = true;
    };

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
      default = { };
    };

    includes = lib.mkOption {
      type = lib.types.listOf lib.types.pathInStore;
      description = "A list of paths to be added as include directories for compilation.";
      default = [ ];
    };

    languages = lib.mkOption {
      type = lib.types.attrsOf hull.types.language;
      default = hull.language.commons;
      defaultText = lib.literalExpression "hull.language.commons";
      description = "The attribute set of available programming languages and their compilation logic.";
    };

    judger = lib.mkOption {
      type = hull.types.judger;
      description = "The judger implementation to use for evaluating solutions.";
      default = hull.judger.batch config { };
      defaultText = lib.literalExpression "hull.judger.batch config { }";
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
      description = "An attribute set of all possible traits that can be used to categorize test cases and define subtasks.";
      default = { };
    };

    generators = lib.mkOption {
      type = lib.types.attrsOf (hull.types.generator config);
      description = "An attribute set of generator programs used to create test case inputs.";
      default = { };
    };

    testCases = lib.mkOption {
      type = lib.types.attrsOf (hull.types.testCase config);
      description = "An attribute set defining all test cases for the problem.";
      default = { };
    };

    samples = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      description = "A list of test cases with `sample` or `sampleLarge` group.";
      default = builtins.filter (
        tc: (builtins.elem "sample" tc.groups) || (builtins.elem "sampleLarge" tc.groups)
      ) (builtins.attrValues config.testCases);
      defaultText = "A filtered list of `problem.testCases` with `sample` or `sampleLarge` group.";
    };

    testCaseInputValidations = lib.mkOption {
      type = lib.types.attrsOf hull.types.inputValidationReport;
      description = "An attribute set describing the input validation report for all test cases.";
      default =
        let
          drvs = lib.mapAttrs (
            tcName:
            { data, groups, ... }:
            hull.validate.drv {
              problemName = config.name;
              testCaseName = tcName;
              validatorWasm = config.validator.cwasm;
              input = data.input;
              readerTraceLevel = if builtins.elem "sample" groups then 2 else 1;
            }
          ) config.testCases;
          links = pkgs.linkFarm "hull-testCaseInputValidations-${config.name}" drvs;
          reports = lib.mapAttrs (tcName: _: lib.importJSON (links + "/${tcName}")) drvs;
        in
        reports;
      defaultText = "Computed by runs the validator on the input file for all test cases.";
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
      default = [ { fullScore = 1.0; } ];
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
      type = lib.types.attrsOf hull.types.problemTarget;
      default = { };
      description = "An attribute set of build targets for the problem, defining final package structures.";
    };

    fullScore = lib.mkOption {
      type = lib.types.numbers.nonnegative;
      description = "Full score of this problem";
      default = builtins.foldl' builtins.add 0.0 (map ({ fullScore, ... }: fullScore) config.subtasks);
      defaultText = "The sum of the full score of all subtasks.";
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
