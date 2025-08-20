{
  lib,
  hull,
  pkgs,
  hullPkgs,
}:

let
  # Helper to get language information for a given source file from a set of available languages.
  getLangInfo =
    problem: src: languages:
    let
      languageName = hull.language.matchBaseName (baseNameOf src) languages;
      language = languages.${languageName};
    in
    {
      inherit languageName language;
    };

  check =
    { checker, ... }@problem:
    { data, ... }@testCase:
    runResult: # Takes the result of a run instead of the whole solution
    solutionName: # for unique derivation names
    let
      runDerivation =
        pkgs.runCommandLocal "hull-check-${problem.name}-${testCase.name}-${solutionName}"
          { nativeBuildInputs = [ hullPkgs.default ]; }
          ''
            cp ${checker.cwasm} cwasm
            cp ${data.input} input
            cp ${runResult.stdout} output
            cp ${data.output} answer
            hull run-wasm \
              cwasm \
              --inherit-stdout \
              --stderr-path=$out \
              --read-file input \
              --read-file output \
              --read-file answer \
              -- input output answer \
            || true
          '';
      checkReport = builtins.fromJSON (builtins.readFile runDerivation);
    in
    {
      inherit (checkReport) status score message;
      readerTraceStacks = checkReport.reader_trace_stacks or [ ];
      evaluatorTraceStacks = checkReport.evaluator_trace_stacks or [ ];
    };
in
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
      allLanguages = problem.languages;
      # Filter languages if specified, and validate that they exist.
      languages =
        if solutionSpecificLanguages == null then
          allLanguages
        else
          lib.filterAttrs (
            n: _:
            (
              if !(builtins.hasAttr n allLanguages) then
                throw "Language `${n}` specified in solutionSpecificLanguages is not defined in problem.languages"
              else
                true
            )
            && (builtins.elem n solutionSpecificLanguages)
          ) allLanguages;

      # Pre-compile extra objects (e.g., graders).
      compiledObjects = map (
        src:
        let
          langInfo = getLangInfo problem src problem.languages;
        in
        langInfo.language.compile.object {
          name = "${problem.name}-${baseNameOf src}";
          inherit src;
          includes = problem.includes;
        }
      ) extraObjects;

      runWasm =
        problem:
        {
          tickLimit,
          memoryLimit,
          data,
          ...
        }@testCase:
        solName: wasm:
        let
          runDerivation =
            pkgs.runCommandLocal "hull-run-${problem.name}-${testCase.name}-${solName}"
              { nativeBuildInputs = [ hullPkgs.default ]; }
              ''
                cp ${wasm} wasm
                cp ${data.input} stdin
                mkdir $out
                hull run-wasm \
                  wasm \
                  --stdin-path=stdin \
                  --stdout-path=$out/stdout \
                  --stderr-path=$out/stderr \
                  --tick-limit=${builtins.toString tickLimit} \
                  --memory-limit=${builtins.toString memoryLimit} \
                  > $out/report.json \
                || true
              '';
        in
        {
          stdout = runDerivation + "/stdout";
          stderr = runDerivation + "/stderr";
          report = builtins.fromJSON (builtins.readFile (runDerivation + "/report.json"));
        };

      run =
        testCase: solution:
        let
          langInfo = getLangInfo problem solution.src languages;
          wasm = langInfo.language.compile.executable {
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
        runWasm problem testCase solution.name cwasm;
    in
    {
      _type = "hullJudger";

      inherit run;

      judge =
        testCase: solution:
        let
          runResult = run testCase solution;
          checkResult =
            if runResult.report.status == "accepted" then
              check problem testCase runResult solution.name
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
          run = runResult;
          check = checkResult;
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
      allLanguages = problem.languages;
      languages =
        if solutionSpecificLanguages == null then
          allLanguages
        else
          lib.filterAttrs (
            n: _:
            (
              if !(builtins.hasAttr n allLanguages) then
                throw "Language '${n}' specified in solutionSpecificLanguages is not defined in problem.languages"
              else
                true
            )
            && (builtins.elem n solutionSpecificLanguages)
          ) allLanguages;

      judge =
        testCase: solution:
        let
          # Compile solution
          solLangInfo = getLangInfo problem solution.src languages;
          solWasm = solLangInfo.language.compile.executable {
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
                  --stderr-path=$out/solution.stderr \
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

                # Create a dummy stdout for the solution's run result, as its real stdout was piped.
                touch $out/solution.stdout
              '';

          runReport = builtins.fromJSON (builtins.readFile (interactionDerivation + "/run_report.json"));
          checkResult = builtins.fromJSON (builtins.readFile (interactionDerivation + "/interactor.stderr"));

          runResult = {
            stdout = interactionDerivation + "/solution.stdout";
            stderr = interactionDerivation + "/solution.stderr";
            report = runReport;
          };

          # Determine final status: if the solution didn't run correctly, that's the status.
          # Otherwise, the status is determined by the interactor/checker.
          status =
            if runResult.report.status != "accepted" then runResult.report.status else checkResult.status;
          score = if runResult.report.status != "accepted" then 0.0 else checkResult.score;
          message =
            if runResult.report.status != "accepted" then
              runResult.report.errorMessage
            else
              checkResult.message;
        in
        {
          inherit
            status
            score
            message
            ;
          run = runResult;
          check = {
            inherit (checkResult) status score message;
            readerTraceStacks = checkResult.reader_trace_stacks or [ ];
          };
        };
    in
    {
      _type = "hullJudger";

      inherit judge;
      run = testCase: solution: (judge testCase solution).run;
    };

  # Judger for "answer only" type problems, where the source is the answer file.
  answerOnlyJudger =
    problem:
    let
      run = testCase: solution: {
        stdout = solution.src;
        stderr = pkgs.writeText "empty-stderr" "";
        report = {
          status = "accepted";
          tick = 0;
          memory = 0;
          exitCode = 0;
          errorMessage = "";
        };
      };
    in
    {
      _type = "hullJudger";

      inherit run;

      judge =
        testCase: solution:
        let
          # The "runResult" is a mock result. The solution's source file is treated as its stdout.
          runResult = run testCase solution;
          # The "check" is real, comparing the submission against the answer.
          checkResult = check problem testCase runResult solution.name;
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
          run = runResult;
          check = checkResult;
        };
    };
}
