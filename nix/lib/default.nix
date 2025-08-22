{
  pkgs,
  hullPkgs,
  typixLib,
  cplib,
}:

let
  problemModule = ./problemModule;
  callSubLib =
    p:
    import p {
      inherit
        hull
        pkgs
        hullPkgs
        typixLib
        ;
      inherit (pkgs) lib;
    };

  hull = {
    overview = callSubLib ./overview;
    check = callSubLib ./check.nix;
    compile = callSubLib ./compile.nix;
    docs = callSubLib ./docs.nix;
    document = callSubLib ./document.nix;
    generate = callSubLib ./generate.nix;
    judger = callSubLib ./judger.nix;
    language = callSubLib ./language.nix;
    runWasm = callSubLib ./runWasm.nix;
    target = callSubLib ./target.nix;
    types = callSubLib ./types.nix;
    validate = callSubLib ./validate.nix;

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

          specialArgs = {
            inherit
              pkgs
              hull
              hullPkgs
              cplib
              ;
          };
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
            solutions."ad-hoc-judge".src = srcPath;
          };

        # Evaluate the problem with the ad-hoc solution injected.
        # This triggers the automatic calculation of testCaseResults, etc.
        evaluatedProblem = pkgs.lib.evalModules {
          modules = [
            problemModule
            problemAttrs
            adhocSolutionModule
          ];
          specialArgs = {
            inherit
              pkgs
              hull
              hullPkgs
              cplib
              ;
          };
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
      builtins.toFile "judge-report.json" (builtins.toJSON reportData);
  };
in
hull
