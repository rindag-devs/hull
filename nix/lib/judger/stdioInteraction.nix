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
}:

# Judger for problems that require interaction via standard I/O.
problem:
{
  solutionSpecificLanguages ? null,
  realTimeLimitSeconds,
}:
let
  languages =
    if solutionSpecificLanguages == null then
      problem.languages
    else
      lib.filterAttrs (
        n: _:
        (
          if !(builtins.hasAttr n problem.languages) then
            throw "Language '${n}' specified in solutionSpecificLanguages is not defined in problem.languages"
          else
            true
        )
        && (builtins.elem n solutionSpecificLanguages)
      ) problem.languages;

  judge =
    testCase: solution:
    let
      # Compile solution
      solWasm = hull.compile.executable {
        inherit languages;
        name = "${problem.name}-solution-${solution.name}";
        src = solution.src;
        includes = problem.includes;
        extraObjects = [ ];
      };
      solCwasm = hull.compile.cwasm {
        name = "${problem.name}-solution-${solution.name}";
        wasm = solWasm;
      };

      # The interactor is the checker program.
      checkerCwasm = problem.checker.cwasm;

    in
    pkgs.runCommandLocal "hull-interact-${problem.name}-${testCase.name}-${solution.name}"
      {
        nativeBuildInputs = [
          hullPkgs.default
          pkgs.jq
        ];
      }
      ''
        mkdir -p $out/outputs

        mkfifo sol_to_intr intr_to_sol
        cp ${solCwasm} solCwasm
        cp ${checkerCwasm} interactorCwasm
        cp ${testCase.data.input} input

        # Start interactor (no resource limits)
        hull run-wasm interactorCwasm \
          --stdin-path=sol_to_intr \
          --stdout-path=intr_to_sol \
          --stderr-path=interactor.json \
          --read-file input \
          -- input &
        intr_pid=$!

        # Start solution (with resource limits)
        timeout ${toString realTimeLimitSeconds}s hull run-wasm solCwasm \
          --stdin-path=intr_to_sol \
          --stdout-path=sol_to_intr \
          --tick-limit=${builtins.toString testCase.tickLimit} \
          --memory-limit=${builtins.toString testCase.memoryLimit} \
          > run.json &
        sol_pid=$!

        set +e
        wait $sol_pid
        sol_exit_code=$?
        set -e

        TLE_RUN_JSON=$(cat <<EOF
        {
          "status": "time_limit_exceeded",
          "tick": ${builtins.toString testCase.tickLimit},
          "memory": 0,
          "exitCode": -1,
          "errorMessage": "Real-time limit exceeded (killed after ${toString realTimeLimitSeconds}s)"
        }
        EOF
        )

        if [ "$sol_exit_code" -eq 124 ] || [ "$sol_exit_code" -eq 137 ]; then
          echo "Solution timed out (real time), exit code $sol_exit_code. Generating TLE report."
          echo "$TLE_RUN_JSON" > run.json
        fi

        wait $intr_pid || true

        run_status=$(jq -r .status run.json)

        if [ "$run_status" == "accepted" ]; then
          final_status=$(jq -r .status interactor.json)
          final_score=$(jq -r .score interactor.json)
          final_message=$(jq -r .message interactor.json)
        else
          final_status=$run_status
          final_score=0.0
          final_message=$(jq -r .errorMessage run.json)
        fi

        tick=$(jq .tick run.json)
        memory=$(jq .memory run.json)

        jq -nc \
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
in
{
  _type = "hullJudger";

  inherit judge;
  generateOutputs = testCase: std: pkgs.emptyDirectory;
}
