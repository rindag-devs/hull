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

  compileExecutableScript = hull.compile.executableMatchScript {
    inherit languages;
    srcExpr = ''"$HULL_SOLUTION_SRC"'';
    outExpr = ''"$HULL_PREPARED_SOLUTION_EXECUTABLE_PATH"'';
    includes = problem.includes;
    extraObjects = [ ];
  };

in
{
  _type = "hullJudger";

  prepareSolution = hull.judger.writeShellApplication {
    name = "hull-judger-stdioInteraction-prepareSolution-${problem.name}";
    inheritPath = false;
    runtimeInputs =
      { targetPkgs, ... }:
      [
        targetPkgs.coreutils
        targetPkgs.jq
      ];
    text =
      { targetHull, ... }:
      let
        targetLanguages = targetHull.language.retarget { inherit targetHull; } languages;
      in
      ''
        cp "$HULL_SOLUTION_SRC" "$HULL_PREPARED_SOLUTION_SRC_PATH"
        ${targetHull.compile.executableMatchScript {
          languages = targetLanguages;
          srcExpr = ''"$HULL_SOLUTION_SRC"'';
          outExpr = ''"$HULL_PREPARED_SOLUTION_EXECUTABLE_PATH"'';
          includes = problem.includes;
          extraObjects = [ ];
        }}
        jq -nc \
          --arg src "$HULL_PREPARED_SOLUTION_SRC_PATH" \
          --arg executable "$HULL_PREPARED_SOLUTION_EXECUTABLE_PATH" \
          '{ src: $src, executable: { path: $executable, drvPath: null } }' > "$HULL_REPORT_PATH"
      '';
  };

  judge = hull.judger.writeShellApplication {
    name = "hull-judger-stdioInteraction-judge-${problem.name}";
    inheritPath = false;
    runtimeInputs =
      { targetHullPkgs, targetPkgs, ... }:
      [
        targetHullPkgs.default
        targetPkgs.coreutils
        targetPkgs.jq
      ];
    text = ''
      workdir=$(mktemp -d)
      cleanup() {
        rm -rf "$workdir"
      }
      trap cleanup EXIT
      cd "$workdir"

      sol_to_intr=sol_to_intr
      intr_to_sol=intr_to_sol
      interactor_json=interactor.json
      run_json=run.json
      sol_wasm=sol.wasm
      interactor_wasm=interactor.wasm
      input_path=input

      mkfifo "$sol_to_intr" "$intr_to_sol"
      cp "$HULL_SOLUTION_EXECUTABLE" "$sol_wasm"
      cp ${problem.checker.wasm} "$interactor_wasm"
      cp "$HULL_INPUT_PATH" "$input_path"

      hull run-wasm "$interactor_wasm" \
        --stdin-path="$sol_to_intr" \
        --stdout-path="$intr_to_sol" \
        --stderr-path="$interactor_json" \
        --read-file input \
        -- input &
      intr_pid=$!

      timeout ${toString realTimeLimitSeconds}s hull run-wasm "$sol_wasm" \
        --stdin-path="$intr_to_sol" \
        --stdout-path="$sol_to_intr" \
        --tick-limit="$HULL_TICK_LIMIT" \
        --memory-limit="$HULL_MEMORY_LIMIT" \
        > "$run_json" &
      sol_pid=$!

      set +e
      wait $sol_pid
      sol_exit_code=$?
      set -e

      TLE_RUN_JSON=$(jq -nc \
        --arg status "time_limit_exceeded" \
        --argjson tick "$HULL_TICK_LIMIT" \
        --argjson memory 0 \
        --argjson exitCode -1 \
        --arg errorMessage "Real-time limit exceeded (killed after ${toString realTimeLimitSeconds}s)" \
        '{
          status: $status,
          tick: $tick,
          memory: $memory,
          exitCode: $exitCode,
          errorMessage: $errorMessage
        }')

      if [ "$sol_exit_code" -eq 124 ] || [ "$sol_exit_code" -eq 137 ]; then
        printf '%s\n' "$TLE_RUN_JSON" > "$run_json"
      fi

      wait $intr_pid || true

      run_status=$(jq -r .status "$run_json")

      if [ "$run_status" = "accepted" ]; then
        final_status=$(jq -r .status "$interactor_json")
        final_score=$(jq -r .score "$interactor_json")
        final_message=$(jq -r .message "$interactor_json")
      else
        final_status=$run_status
        final_score=0.0
        final_message=$(jq -r .errorMessage "$run_json")
      fi

      tick=$(jq .tick "$run_json")
      memory=$(jq .memory "$run_json")

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
        }' > "$HULL_REPORT_PATH"
    '';
  };

  generateOutputs = hull.judger.writeShellApplication {
    name = "hull-judger-stdioInteraction-generateOutputs-${problem.name}";
    inheritPath = false;
    runtimeInputs = { targetPkgs, ... }: [ targetPkgs.coreutils ];
    text = ''
      mkdir -p "$HULL_OUTPUTS_DIR"
    '';
  };
}
