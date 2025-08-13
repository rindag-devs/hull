{
  lib,
  hull,
  config,
  ...
}:

{
  imports = [ ./assertions.nix ];

  options = {
    name = lib.mkOption { type = hull.types.validNameStr; };

    includes = lib.mkOption {
      type = lib.types.listOf lib.types.pathInStore;
      default = [ ];
    };

    languages = lib.mkOption {
      type = lib.types.attrsOf hull.types.language;
      default = hull.language.commons;
    };

    judger = lib.mkOption {
      type = hull.types.judger;
      default = hull.batchJudger { };
    };

    checker = lib.mkOption { type = hull.types.checker config; };

    validator = lib.mkOption { type = hull.types.validator config; };

    traits = lib.mkOption {
      type = lib.types.listOf hull.types.validNameStr;
      default = [ ];
    };

    generators = lib.mkOption {
      type = lib.types.attrsOf (hull.types.generator config);
      default = { };
    };

    testCases = lib.mkOption {
      type = lib.types.attrsOf (hull.types.testCase config);
      default = { };
    };

    tickLimit = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = null;
    };

    memoryLimit = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = null;
    };

    subtasks = lib.mkOption {
      type = lib.types.listOf (hull.types.subtask config);
      default = [ ];
    };

    solutions = lib.mkOption {
      type = lib.types.attrsOf (hull.types.solution config);
      default = { };
    };

    mainCorrectSolution = lib.mkOption {
      type = lib.types.attrs; # Avoid double evaluation
      readOnly = true;
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
    };

    targets = lib.mkOption {
      type = lib.types.attrsOf hull.types.target;
      default = { };
    };

    targetOutputs = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      default = builtins.mapAttrs (targetName: target: target config) config.targets;
    };
  };
}
