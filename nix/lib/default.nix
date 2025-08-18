{
  pkgs,
  hullPkgs,
  typixLib,
}:

let
  problemModule = ./problemModule;

  hull = {
    compile = import ./compile.nix { inherit hull pkgs hullPkgs; };
    docs = import ./docs.nix { inherit hull pkgs; };
    document = import ./document.nix { inherit pkgs typixLib; };
    generate = import ./generate.nix { inherit hull pkgs hullPkgs; };
    judge = import ./judge.nix { inherit pkgs hullPkgs; };
    judger = import ./judger.nix { inherit pkgs; };
    language = import ./language.nix { inherit pkgs hullPkgs; };
    target = import ./target.nix { inherit hull pkgs; };
    types = import ./types.nix {
      inherit hull;
      inherit (pkgs) lib;
    };
    validate = import ./validate.nix { inherit pkgs hullPkgs; };

    inherit problemModule;

    # A helper function to evaluate a user's problem definition.
    # It takes a user-provided attribute set (the problem definition)
    # and evaluates it against our module system.
    evalProblem =
      problemAttrs:
      let
        problem = pkgs.lib.evalModules {
          # The list of modules to evaluate.
          # We have our main problem module and the user's configuration.
          modules = [
            problemModule
            problemAttrs
            (
              { ... }:
              {
                config.problemAttrs = problemAttrs;
              }
            )
          ];

          specialArgs = { inherit pkgs hull; };
        };

        problemAssertWarn =
          pkgs.lib.asserts.checkAssertWarn problem.config.assertions problem.config.warnings
            problem;
      in
      problemAssertWarn;

    # Judges a single source file against a problem definition.
    # This function orchestrates the entire judging process within Nix
    # and produces a derivation containing the final JSON report.
    judgeSingleFile =
      problemAttrs: srcPath:
      let
        # Define a module that injects the user's source file as a temporary solution.
        adhocSolutionModule =
          { config, ... }:
          {
            solutions."ad-hoc-judge" = {
              src = srcPath;
              # We don't need predictions for an ad-hoc judge.
              subtaskPredictions = { };
            };
          };

        # Evaluate the problem with the ad-hoc solution injected.
        # This triggers the automatic calculation of testCaseResults, etc.
        evaluatedProblem = pkgs.lib.evalModules {
          modules = [
            problemModule
            problemAttrs
            adhocSolutionModule
          ];
          specialArgs = { inherit pkgs hull; };
        };

        # Extract the results for our temporary solution.
        judgedSolution = evaluatedProblem.config.solutions."ad-hoc-judge";

        # Sanitize the results to create a clean JSON report.
        reportData = {
          score = judgedSolution.score;
          fullScore = evaluatedProblem.config.fullScore;
          subtaskResults = map (
            { fst, snd }: builtins.removeAttrs snd [ "testCases" ] // { inherit (fst) fullScore; }
          ) (pkgs.lib.zipLists evaluatedProblem.config.subtasks judgedSolution.subtaskResults);
          testCaseResults = judgedSolution.testCaseResults;
        };
      in
      # Create a derivation that contains the final report.
      pkgs.writeText "judge-report.json" (builtins.toJSON reportData);
  };
in
hull
