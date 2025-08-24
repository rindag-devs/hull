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
}:

# Judger for traditional batch problems and problems with custom graders.
problem:
{
  solutionSpecificLanguages ? null,
  # List of src for extra (usually grader) objects.
  extraObjects ? [ ],
}:
let
  # Filter languages if specified, and validate that they exist.
  languages =
    if solutionSpecificLanguages == null then
      problem.languages
    else
      lib.filterAttrs (
        n: _:
        (
          if !(builtins.hasAttr n languages) then
            throw "Language `${n}` specified in solutionSpecificLanguages is not defined in problem.languages"
          else
            true
        )
        && (builtins.elem n solutionSpecificLanguages)
      ) problem.languages;

  # Pre-compile extra objects (e.g., graders).
  compiledObjects = map (
    src:
    hull.compile.object {
      name = "${problem.name}-${baseNameOf src}";
      inherit src;
      inherit (problem) languages includes;
    }
  ) extraObjects;

  getRunScript =
    {
      data,
      tickLimit,
      memoryLimit,
      ...
    }:
    solution: ensureAccepted:
    let
      wasm = hull.compile.executable {
        inherit languages;
        name = "${problem.name}-solution-${solution.name}";
        src = solution.src;
        includes = problem.includes;
        extraObjects = compiledObjects;
      };
      cwasm = hull.compile.cwasm {
        name = "${problem.name}-solution-${solution.name}";
        inherit wasm;
      };
    in
    hull.runWasm.script {
      wasm = cwasm;
      stdin = data.input;
      inherit tickLimit memoryLimit ensureAccepted;
    };
in
{
  _type = "hullJudger";

  generateOutputs =
    testCase: std:
    let
      script = getRunScript testCase std true;
    in
    pkgs.runCommandLocal "hull-generateOutput-${problem.name}-${testCase.name}" { } ''
      ${script}
      mkdir $out
      install -Tm644 stdout $out/output
    '';

  judge =
    { data, ... }@testCase:
    solution:
    let
      runScript = getRunScript testCase solution false;
      checkScript = hull.check.script {
        checkerWasm = problem.checker.cwasm;
        input = data.input;
        output = "$run_stdout";
        answer = data.outputs + "/output";
      };
    in
    pkgs.runCommandLocal "hull-judge-${problem.name}-${testCase.name}-${solution.name}"
      { nativeBuildInputs = [ pkgs.jq ]; }
      ''
        mkdir -p $out/outputs

        pushd $(mktemp -d) > /dev/null
        ${runScript}
        run_status=$(jq -r .status report.json)
        run_message=$(jq -r .status report.json)
        install -Tm644 stdout $out/outputs/output
        run_stdout="$PWD/stdout"

        tick=$(jq .tick report.json)
        memory=$(jq .memory report.json)
        final_message=$(jq -r .errorMessage report.json)
        final_status="$run_status"
        final_score=0.0
        popd > /dev/null

        if [ "$run_status" == "accepted" ]; then
          pushd $(mktemp -d) > /dev/null
          ${checkScript}
          final_status=$(jq -r .status check.json)
          final_score=$(jq -r .score check.json)
          final_message=$(jq -r .message check.json)
          popd > /dev/null
        fi

        ${lib.getExe pkgs.jq} -nc \
          --arg status "$final_status" \
          --argjson score "$final_score" \
          --arg message "$final_message" \
          --argjson tick "$tick" \
          --argjson memory "$memory" \
          '{
            status: $status,
            score: $score,
            message: $message,
            tick: $tick,
            memory: $memory
          }' > $out/report.json
      '';
}
