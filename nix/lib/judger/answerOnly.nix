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
  hull,
  pkgs,
  lib,
}:

# Judger for "answer only" type problems, where the source is the answer file.
problem: {
  _type = "hullJudger";

  generateOutputs =
    testCase:
    { src, ... }:
    pkgs.runCommandLocal "hull-generateOutputs-${problem.name}-${testCase.name}" { } ''
      mkdir $out
      install -Tm644 ${src} $out/output
    '';

  judge =
    { data, ... }@testCase:
    { src, ... }@solution:
    let
      # The "check" is real, comparing the submission against the answer.
      checkScript = hull.check.script {
        checkerWasm = problem.checker.cwasm;
        input = data.input;
        output = src;
        answer = data.outputs + "/output";
      };
    in
    pkgs.runCommandLocal "hull-judge-${problem.name}-${testCase.name}-${solution.name}"
      { nativeBuildInputs = [ pkgs.jq ]; }
      ''
        ${checkScript}
        mkdir -p $out/outputs

        final_status=$(jq -r .status check.json)
        final_score=$(jq -r .score check.json)
        final_message=$(jq -r .message check.json)

        jq -nc \
          --arg status "$final_status" \
          --argjson score "$final_score" \
          --arg message "$final_message" \
          '{
            status: $status,
            score: $score,
            message: $message,
            tick: 0,
            memory: 0
          }' > $out/report.json
          
          install -Tm644 ${src} $out/outputs/output
      '';
}
