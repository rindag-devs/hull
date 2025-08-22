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

{
  # Judger for traditional batch problems and problems with custom graders.
  batchJudger =
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

      run =
        {
          data,
          tickLimit,
          memoryLimit,
          ...
        }@testCase:
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
        hull.runWasm {
          name = "hull-run-${problem.name}-${testCase.name}-${solution.name}";
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
          runResult = run testCase std true;
          output = runResult.stdout;
        in
        {
          inherit output;
        };

      judge =
        { data, ... }@testCase:
        solution:
        let
          runResult = run testCase solution false;
          checkResult =
            if runResult.report.status == "accepted" then
              hull.check {
                problemName = problem.name;
                testCaseName = testCase.name;
                solutionName = solution.name;
                checkerWasm = problem.checker.cwasm;
                input = data.input;
                output = runResult.stdout;
                answer = data.outputs.output;
              }
            else
              null;
          status = if checkResult != null then checkResult.status else runResult.report.status;
          score = if checkResult != null then checkResult.score else 0.0;
          message = if checkResult != null then checkResult.message else runResult.report.errorMessage;
        in
        {
          inherit
            status
            score
            message
            ;
          inherit (runResult.report) tick memory;
          outputs.output = runResult.stdout;
        };
    };

  # Judger for problems that require interaction via standard I/O.
  stdioInteractionJudger =
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

          # Run the interaction using named pipes.
          interactionDerivation =
            pkgs.runCommandLocal "hull-interact-${problem.name}-${testCase.name}-${solution.name}"
              {
                nativeBuildInputs = [
                  hullPkgs.default
                  pkgs.coreutils
                ];
              }
              ''
                mkdir $out
                mkfifo sol_to_intr intr_to_sol
                cp ${solCwasm} solCwasm
                cp ${checkerCwasm} interactorCwasm
                cp ${testCase.data.input} input

                # Start interactor (no resource limits)
                hull run-wasm interactorCwasm \
                  --stdin-path=sol_to_intr \
                  --stdout-path=intr_to_sol \
                  --stderr-path=$out/interactor.stderr \
                  --read-file input \
                  -- input &
                intr_pid=$!

                # Start solution (with resource limits)
                timeout ${toString realTimeLimitSeconds}s hull run-wasm solCwasm \
                  --stdin-path=intr_to_sol \
                  --stdout-path=sol_to_intr \
                  --tick-limit=${builtins.toString testCase.tickLimit} \
                  --memory-limit=${builtins.toString testCase.memoryLimit} \
                  > $out/run_report.json &
                sol_pid=$!

                set +e
                wait $sol_pid
                sol_exit_code=$?
                set -e

                TLE_REPORT_JSON=$(cat <<EOF
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
                  echo "$TLE_REPORT_JSON" > $out/run_report.json
                fi

                wait $intr_pid || true
              '';

          runReport = builtins.fromJSON (builtins.readFile (interactionDerivation + "/run_report.json"));
          checkResult = builtins.fromJSON (builtins.readFile (interactionDerivation + "/interactor.stderr"));

          # Determine final status: if the solution didn't run correctly, that's the status.
          # Otherwise, the status is determined by the interactor/checker.
          status = if runReport.status != "accepted" then runReport.status else checkResult.status;
          score = if runReport.status != "accepted" then 0.0 else checkResult.score;
          message = if runReport.status != "accepted" then runReport.errorMessage else checkResult.message;
        in
        {
          inherit
            status
            score
            message
            ;
          inherit (runReport) tick memory;
          outputs = { };
        };
    in
    {
      _type = "hullJudger";

      inherit judge;
      generateOutputs = testCase: std: { };
    };

  # Judger for "answer only" type problems, where the source is the answer file.
  answerOnlyJudger = problem: {
    _type = "hullJudger";

    generateOutputs =
      testCase:
      { src, ... }:
      {
        output = src;
      };

    judge =
      { data, ... }@testCase:
      { src, ... }@solution:
      let
        # The "check" is real, comparing the submission against the answer.
        checkResult = hull.check {
          problemName = problem.name;
          testCaseName = testCase.name;
          solutionName = solution.name;
          checkerWasm = problem.checker.cwasm;
          input = data.input;
          output = src;
          answer = data.outputs.output;
        };
        status = checkResult.status;
        score = checkResult.score;
        message = checkResult.message;
      in
      {
        inherit
          status
          score
          message
          ;
        tick = 0;
        memory = 0;
        outputs.output = solution.src;
      };
  };
}
