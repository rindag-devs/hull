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

# Stdio-only judger for traditional batch problems and linked custom graders.
# Extra objects are linked into the contestant program and do not create runtime file bindings.
problem:
{
  solutionSpecificLanguages ? null,
  # List of src for extra (usually grader) objects.
  extraObjects ? [ ],
}:
let
  dynamicString = hull.runWasm.dynamicString;
  dynamicNumber = hull.runWasm.dynamicNumber;
  contestantRequest = required_accepted: {
    report_path = "report.json";
    files = [
      {
        name = "stdin";
        kind = "regular";
        host_path = dynamicString "HULL_INPUT_PATH";
        max_permissions = 4;
        size_limit = problem.fileSizeLimit;
      }
      {
        name = "stdout";
        kind = "regular";
        host_path = "stdout";
        max_permissions = 2;
        size_limit = problem.fileSizeLimit;
      }
      {
        name = "stderr";
        kind = "regular";
        host_path = "stderr";
        max_permissions = 2;
        size_limit = problem.fileSizeLimit;
      }
    ];
    programs = [
      {
        name = "solution";
        wasm_path = dynamicString "HULL_SOLUTION_EXECUTABLE";
        arguments = [ ];
        tick_limit = dynamicNumber "HULL_TICK_LIMIT";
        memory_limit = dynamicNumber "HULL_MEMORY_LIMIT";
        inherit required_accepted;
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
            file = "stdin";
            permissions = 4;
          }
          {
            file = "stdout";
            permissions = 2;
          }
          {
            file = "stderr";
            permissions = 2;
          }
        ];
      }
    ];
  };
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
    hull.compile.object.drv {
      name = "${problem.name}-${baseNameOf src}";
      inherit src;
      inherit (problem) languages includes;
    }
  ) extraObjects;
in
{
  _type = "hullJudger";

  prepareSolution = hull.judger.writeShellApplication {
    name = "hull-judger-batch-prepareSolution-${problem.name}";
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
          inherit languages;
          srcExpr = ''"$HULL_SOLUTION_SRC"'';
          outExpr = ''"$HULL_PREPARED_SOLUTION_EXECUTABLE_PATH"'';
          includes = problem.includes;
          extraObjects = compiledObjects;
        }}
        jq -nc \
          --arg src "$HULL_PREPARED_SOLUTION_SRC_PATH" \
          --arg executable "$HULL_PREPARED_SOLUTION_EXECUTABLE_PATH" \
          '{ src: $src, executable: { path: $executable, drv_path: null } }' > "$HULL_REPORT_PATH"
      '';
  };

  generateOutputs = hull.judger.writeShellApplication {
    name = "hull-judger-batch-generateOutputs-${problem.name}";
    inheritPath = false;
    runtimeInputs = { targetPkgs, ... }: [ targetPkgs.coreutils ];
    text =
      { targetHull, ... }:
      ''
        ${targetHull.runWasm.script {
          request = contestantRequest true;
        }}
        mkdir -p "$HULL_OUTPUTS_DIR"
        install -Tm644 stdout "$HULL_OUTPUTS_DIR/output"
      '';
  };

  judge = hull.judger.writeShellApplication {
    name = "hull-judger-batch-judge-${problem.name}";
    inheritPath = false;
    runtimeInputs =
      { targetPkgs, ... }:
      [
        targetPkgs.coreutils
        targetPkgs.jq
      ];
    text =
      { targetPkgs, targetHull, ... }:
      ''
        ${targetHull.runWasm.script {
          request = contestantRequest false;
        }}
        run_status=$(jq -r '.results[] | select(.program == "solution") | .status' report.json)
        install -Tm644 stdout "$HULL_OUTPUTS_DIR/output"
        run_stdout="$PWD/stdout"
        answer_path="$HULL_OFFICIAL_OUTPUTS_DIR/output"

        tick=$(jq '.results[] | select(.program == "solution") | .tick' report.json)
        memory=$(jq '.results[] | select(.program == "solution") | .memory' report.json)
        final_message=$(jq -r '.results[] | select(.program == "solution") | .error_message // ""' report.json)
        final_status="$run_status"
        final_score=0.0

        if [ "$run_status" = "accepted" ]; then
          ${targetHull.check.script {
            checkerWasm = problem.checker.wasm;
            input = targetHull.runWasm.dynamicString "HULL_INPUT_PATH";
            output = targetHull.runWasm.dynamicString "run_stdout";
            answer = targetHull.runWasm.dynamicString "answer_path";
            fileSizeLimits = {
              input = "tool";
              output = problem.fileSizeLimit;
              answer = "tool";
            };
          }}
          final_status=$(jq -r .status check.json)
          final_score=$(jq -r .score check.json)
          final_message=$(jq -r .message check.json)
        fi

        ${lib.getExe targetPkgs.jq} -nc \
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
}
