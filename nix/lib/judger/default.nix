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
  hullPkgs,
  ...
}:

let
  exportEnv = name: value: ''
    export ${name}=${lib.escapeShellArg value}
  '';

  exportPathEnv = name: value: ''
    export ${name}=${lib.escapeShellArg "${value}"}
  '';

  exportOptionalEnv =
    name: value:
    if value == null then
      ''
        unset ${name}
      ''
    else
      exportEnv name value;

  getPreparedSolution =
    problem: solution:
    if problem.judger ? prepareSolution then
      problem.judger.prepareSolution solution
    else
      throw ''
        Judger `${problem.name}` uses the packaged runner interface but does not define `prepareSolution`.
      '';

  runPackagedRunner =
    {
      problem,
      testCase,
      solution,
      runner,
      mode,
    }:
    let
      # Packaged judgers expose executable derivations. Hull injects a uniform
      # environment contract so every judger can be run the same way, regardless
      # of its internal workflow.
      runnerExe =
        if builtins.isString runner || builtins.isPath runner then runner else lib.getExe runner;
      preparedSolution = getPreparedSolution problem solution;
      outName =
        if mode == "generateOutputs" then
          "hull-generateOutput-${problem.name}-${testCase.name}"
        else
          "hull-judge-${problem.name}-${testCase.name}-${solution.name}";
    in
    pkgs.runCommandLocal outName { } ''
      ${exportEnv "HULL_MODE" mode}
      ${exportEnv "HULL_TESTCASE_NAME" testCase.name}
      ${exportEnv "HULL_SOLUTION_NAME" solution.name}
      ${exportPathEnv "HULL_INPUT_PATH" testCase.data.input}
      ${exportEnv "HULL_TICK_LIMIT" (toString testCase.tickLimit)}
      ${exportEnv "HULL_MEMORY_LIMIT" (toString testCase.memoryLimit)}
      ${exportPathEnv "HULL_SOLUTION_SRC" (preparedSolution.src or solution.src)}
      ${exportOptionalEnv "HULL_SOLUTION_EXECUTABLE" (preparedSolution.executable or null)}

      ${
        if mode == "judge" then
          exportPathEnv "HULL_OFFICIAL_OUTPUTS_DIR" testCase.data.outputs
        else
          ''
            unset HULL_OFFICIAL_OUTPUTS_DIR
          ''
      }

      ${
        if mode == "generateOutputs" then
          ''
            export HULL_OUTPUTS_DIR="$out"
            unset HULL_REPORT_PATH
          ''
        else
          ''
            mkdir -p "$out/outputs"
            export HULL_OUTPUTS_DIR="$out/outputs"
            export HULL_REPORT_PATH="$out/report.json"
          ''
      }

      ${runnerExe}
    '';
in
{
  batch = import ./batch.nix { inherit lib hull pkgs; };

  stdioInteraction = import ./stdioInteraction.nix {
    inherit
      lib
      hull
      pkgs
      hullPkgs
      ;
  };

  answerOnly = import ./answerOnly.nix { inherit lib hull pkgs; };

  runGenerateOutputs =
    problem: testCase: solution:
    if builtins.isFunction problem.judger.generateOutputs then
      problem.judger.generateOutputs testCase solution
    else
      runPackagedRunner {
        inherit problem testCase solution;
        runner = problem.judger.generateOutputs;
        mode = "generateOutputs";
      };

  runJudge =
    problem: testCase: solution:
    if builtins.isFunction problem.judger.judge then
      problem.judger.judge testCase solution
    else
      runPackagedRunner {
        inherit problem testCase solution;
        runner = problem.judger.judge;
        mode = "judge";
      };
}
