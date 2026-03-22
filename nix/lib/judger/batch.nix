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

in
{
  _type = "hullJudger";

  prepareSolution =
    solution:
    let
      # Batch-style packaged judgers execute a precompiled contestant program,
      # so prepareSolution materializes the executable expected by the runner.
      wasm = hull.compile.executable {
        inherit languages;
        name = "${problem.name}-solution-${solution.name}";
        src = solution.src;
        includes = problem.includes;
        extraObjects = compiledObjects;
      };
    in
    {
      src = solution.src;
      executable = hull.compile.cwasm {
        name = "${problem.name}-solution-${solution.name}";
        inherit wasm;
      };
    };

  generateOutputs = pkgs.writeShellApplication {
    name = "hull-judger-batch-generateOutputs-${problem.name}";
    inheritPath = false;
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      ${hull.runWasm.script {
        wasm = "$HULL_SOLUTION_EXECUTABLE";
        stdin = "$HULL_INPUT_PATH";
        tickLimit = "$HULL_TICK_LIMIT";
        memoryLimit = "$HULL_MEMORY_LIMIT";
        ensureAccepted = true;
      }}
      mkdir -p "$HULL_OUTPUTS_DIR"
      install -Tm644 stdout "$HULL_OUTPUTS_DIR/output"
    '';
  };

  judge = pkgs.writeShellApplication {
    name = "hull-judger-batch-judge-${problem.name}";
    inheritPath = false;
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      ${hull.runWasm.script {
        wasm = "$HULL_SOLUTION_EXECUTABLE";
        stdin = "$HULL_INPUT_PATH";
        tickLimit = "$HULL_TICK_LIMIT";
        memoryLimit = "$HULL_MEMORY_LIMIT";
        ensureAccepted = false;
      }}
      run_status=$(jq -r .status report.json)
      install -Tm644 stdout "$HULL_OUTPUTS_DIR/output"
      run_stdout="$PWD/stdout"

      tick=$(jq .tick report.json)
      memory=$(jq .memory report.json)
      final_message=$(jq -r .errorMessage report.json)
      final_status="$run_status"
      final_score=0.0

      if [ "$run_status" = "accepted" ]; then
        ${hull.check.script {
          checkerWasm = problem.checker.cwasm;
          input = "$HULL_INPUT_PATH";
          output = "$run_stdout";
          answer = "$HULL_OFFICIAL_OUTPUTS_DIR/output";
        }}
        final_status=$(jq -r .status check.json)
        final_score=$(jq -r .score check.json)
        final_message=$(jq -r .message check.json)
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
        }' > "$HULL_REPORT_PATH"
    '';
  };
}
