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
  pkgs,
  hull,
  hullPkgs,
  cplib,
  ...
}:

# Judges a single source file against a problem definition.
# This function orchestrates the entire judging process within Nix
# and produces a derivation containing the final JSON report.
problemAttrs: extraSpecialArgs: srcPath:
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
      hull.problemModule
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
    }
    // extraSpecialArgs;
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
pkgs.writeText "judge-report.json" (builtins.toJSON reportData)
