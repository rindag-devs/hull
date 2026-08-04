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

# Runs the solution and interactor in one deterministic session with bounded in-process pipes.
# A connected protocol deadlock produces time_limit_exceeded without a wall-clock timeout option.
problem:
let
  # Languages available to solutions.
  solutionLanguages = problem.solutionLanguages;

  request = {
    report_path = "session-report.json";
    files = [
      {
        name = "input";
        kind = "regular";
        host_path = hull.runWasm.dynamicString "HULL_INPUT_PATH";
        max_permissions = 4;
        size_limit = problem.fileSizeLimit;
      }
      {
        name = "solution_stderr";
        kind = "regular";
        host_path = "solution.stderr";
        max_permissions = 2;
        size_limit = problem.fileSizeLimit;
      }
      {
        name = "interactor_report";
        kind = "regular";
        host_path = "interactor.json";
        max_permissions = 2;
        size_limit = "tool";
      }
      {
        name = "solution_to_interactor";
        kind = "pipe";
        capacity = 1048576;
        size_limit = problem.fileSizeLimit;
      }
      {
        name = "interactor_to_solution";
        kind = "pipe";
        capacity = 1048576;
        size_limit = "tool";
      }
    ];
    programs = [
      {
        name = "solution";
        wasm_path = hull.runWasm.dynamicString "HULL_SOLUTION_EXECUTABLE";
        arguments = [ ];
        tick_limit = hull.runWasm.dynamicNumber "HULL_TICK_LIMIT";
        memory_limit = hull.runWasm.dynamicNumber "HULL_MEMORY_LIMIT";
        required_accepted = false;
        file_system = {
          directories = [
            {
              path = ".";
              permissions = 5;
            }
          ];
          bindings = [ ];
        };
        initial_descriptors = [
          {
            file = "interactor_to_solution";
            permissions = 4;
          }
          {
            file = "solution_to_interactor";
            permissions = 2;
          }
          {
            file = "solution_stderr";
            permissions = 2;
          }
        ];
      }
      {
        name = "interactor";
        wasm_path = toString problem.checker.wasm;
        arguments = [ "input" ];
        tick_limit = "tool";
        memory_limit = "tool";
        required_accepted = false;
        file_system = {
          directories = [
            {
              path = ".";
              permissions = 5;
            }
          ];
          bindings = [
            {
              path = "input";
              file = "input";
              permissions = 4;
            }
          ];
        };
        initial_descriptors = [
          {
            file = "solution_to_interactor";
            permissions = 4;
          }
          {
            file = "interactor_to_solution";
            permissions = 2;
          }
          {
            file = "interactor_report";
            permissions = 2;
          }
        ];
      }
    ];
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
      ''
        cp "$HULL_SOLUTION_SRC" "$HULL_PREPARED_SOLUTION_SRC_PATH"
        ${targetHull.compile.executableMatchScript {
          languages = solutionLanguages;
          srcExpr = ''"$HULL_SOLUTION_SRC"'';
          outExpr = ''"$HULL_PREPARED_SOLUTION_EXECUTABLE_PATH"'';
          includes = problem.solutionIncludes;
          extraObjects = [ ];
        }}
        jq -nc \
          --arg src "$HULL_PREPARED_SOLUTION_SRC_PATH" \
          --arg executable "$HULL_PREPARED_SOLUTION_EXECUTABLE_PATH" \
          '{ src: $src, executable: { path: $executable, drv_path: null } }' > "$HULL_REPORT_PATH"
      '';
  };

  judge = hull.judger.writeShellApplication {
    name = "hull-judger-stdioInteraction-judge-${problem.name}";
    inheritPath = false;
    runtimeInputs =
      { targetPkgs, ... }:
      [
        targetPkgs.coreutils
        targetPkgs.jq
      ];
    text =
      { targetHull, ... }:
      ''
        ${targetHull.runWasm.script { inherit request; }}

        solution_status=$(jq -r '.results[] | select(.program == "solution") | .status' session-report.json)
        tick=$(jq '.results[] | select(.program == "solution") | .tick' session-report.json)
        memory=$(jq '.results[] | select(.program == "solution") | .memory' session-report.json)

        if [ "$solution_status" != "accepted" ]; then
          final_status=$solution_status
          final_score=0.0
          final_message=$(jq -r '.results[] | select(.program == "solution") | .error_message // ""' session-report.json)
        else
          if ! jq -e \
            '.results[] | select(.program == "interactor" and (.status == "accepted" or (.status == "runtime_error" and .exit_code != null)))' \
            session-report.json >/dev/null || ! jq -e \
            '.status | IN("accepted", "wrong_answer", "partially_correct", "internal_error")' \
            interactor.json >/dev/null 2>&1; then
            final_status=internal_error
            final_score=0.0
            final_message=$(jq -r '.results[] | select(.program == "interactor") | .error_message // "Interactor failed to produce a valid report"' session-report.json)
          else
            final_status=$(jq -r .status interactor.json)
            final_score=$(jq -r .score interactor.json)
            final_message=$(jq -r .message interactor.json)
          fi
        fi

        jq -nc \
          --arg status "$final_status" \
          --argjson score "$final_score" \
          --arg message "$final_message" \
          --argjson tick "$tick" \
          --argjson memory "$memory" \
          '{ status: $status, score: $score, message: $message, tick: $tick, memory: $memory }' \
          > "$HULL_REPORT_PATH"
      '';
  };

  generateOutputs = hull.judger.writeShellApplication {
    name = "hull-judger-stdioInteraction-generateOutputs-${problem.name}";
    inheritPath = false;
    runtimeInputs = { targetPkgs, ... }: [ targetPkgs.coreutils ];
    text = ''mkdir -p "$HULL_OUTPUTS_DIR"'';
  };
}
