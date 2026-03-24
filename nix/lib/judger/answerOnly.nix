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

  # Answer-only problems do not execute submissions; the runner only needs the
  # submitted file itself.
  prepareSolution = solution: { src = solution.src; };

  generateOutputs = pkgs.writeShellApplication {
    name = "hull-judger-answerOnly-generateOutputs-${problem.name}";
    inheritPath = false;
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      mkdir -p "$HULL_OUTPUTS_DIR"
      install -Tm644 "$HULL_SOLUTION_SRC" "$HULL_OUTPUTS_DIR/output"
    '';
  };

  judge = pkgs.writeShellApplication {
    name = "hull-judger-answerOnly-judge-${problem.name}";
    inheritPath = false;
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      ${hull.check.script {
        checkerWasm = problem.checker.wasm;
        input = "$HULL_INPUT_PATH";
        output = "$HULL_SOLUTION_SRC";
        answer = "$HULL_OFFICIAL_OUTPUTS_DIR/output";
      }}

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
        }' > "$HULL_REPORT_PATH"

      install -Tm644 "$HULL_SOLUTION_SRC" "$HULL_OUTPUTS_DIR/output"
    '';
  };
}
