{
  hull,
  config,
  lib,
  pkgs,
  ...
}:

{
  judger =
    let
      transformSrc = ./transform.20.cpp;
      transformWasm = hull.compile.executable {
        inherit (config) languages includes;
        src = transformSrc;
        name = "${config.name}-transform";
        extraObjects = [ ];
      };
      transformCwasm = hull.compile.cwasm {
        name = "${config.name}-transform";
        wasm = transformWasm;
      };

      # This function encapsulates the two-phase execution logic.
      # It's used by both `generateOutputs` and `judge`.
      runTwoPhase =
        {
          testCase,
          solution,
          # If true, throw an error on non-accepted status.
          # If false, just return the report.
          ensureAccepted,
          # If true, perform checks against standard answers.
          # If false, this is a generation run, so no checks needed.
          performCheck,
        }:
        let
          # --- Compile solution ---
          solutionWasm = hull.compile.executable {
            inherit (config) languages includes;
            src = solution.src;
            name = "${config.name}-solution";
            extraObjects = [ ];
          };
          solutionCwasm = hull.compile.cwasm {
            name = "${config.name}-solution";
            wasm = solutionWasm;
          };

          # --- Phase 1: Encoding ---

          # Run the solution to get the encoded output.
          # Resource limits are applied here.
          runResult1 = hull.runWasm {
            name = "hull-run-phase1-${config.name}-${testCase.name}-${solution.name}";
            wasm = solutionCwasm;
            stdin = testCase.data.input;
            tickLimit = testCase.tickLimit;
            memoryLimit = testCase.memoryLimit;
            inherit ensureAccepted;
          };

          # The checker expects a type prefix (0 for encode, 1 for decode).
          # We create the full output file for the first phase.
          firstOut = pkgs.writeText "firstOut.txt" ''
            0
            ${builtins.readFile runResult1.stdout}
          '';

          # If checking is enabled, compare the encoded output with the standard answer.
          checkResult1 =
            if performCheck then
              hull.check {
                problemName = config.name;
                testCaseName = testCase.name;
                solutionName = solution.name;
                checkerWasm = config.checker.cwasm;
                input = testCase.data.input;
                output = firstOut;
                answer = testCase.data.outputs.first;
              }
            else
              null;

          # --- Transformation Step ---

          # Run the transform program to generate the input for the second phase.
          # The transform program itself is not resource-limited and must always succeed.
          transformResult = hull.runWasm {
            name = "hull-transform-${config.name}-${testCase.name}-${solution.name}";
            wasm = transformCwasm;
            arguments = [ "--salt=${builtins.hashFile "sha256" testCase.data.input}" ];
            stdin = testCase.data.input;
            inputFiles = {
              # The transform program reads the encoded output from this file.
              firstOut = firstOut;
            };
            ensureAccepted = true;
          };
          secondIn = transformResult.stdout;

          # The generated input for the second phase must be valid.
          # A failure here indicates a problem with the transform logic or the problem setup, not the user's solution.
          validationResult = hull.validate {
            problemName = config.name;
            testCaseName = testCase.name;
            validatorWasm = config.validator.cwasm;
            input = secondIn;
          };

          # --- Phase 2: Decoding ---

          # Run the solution again for the decoding phase.
          # Resource limits are applied here as well.
          runResult2 =
            if validationResult.status != "valid" then
              throw "Validation for the second phase input failed for test case ${testCase.name}. Validator output: ${builtins.toJSON validationResult}"
            else
              hull.runWasm {
                name = "hull-run-phase2-${config.name}-${testCase.name}-${solution.name}";
                wasm = solutionCwasm;
                stdin = secondIn;
                tickLimit = testCase.tickLimit;
                memoryLimit = testCase.memoryLimit;
                inherit ensureAccepted;
              };

          # Create the full output file for the second phase.
          secondOut = pkgs.writeText "secondOut.txt" ''
            1
            ${builtins.readFile runResult2.stdout}
          '';

          # If checking is enabled, compare the decoded output with the standard answer.
          checkResult2 =
            if performCheck then
              hull.check {
                problemName = config.name;
                testCaseName = testCase.name;
                solutionName = solution.name;
                checkerWasm = config.checker.cwasm;
                input = secondIn;
                output = secondOut;
                answer = testCase.data.outputs.second;
              }
            else
              null;
        in
        {
          # Return all intermediate results for the caller to decide the final outcome.
          inherit
            runResult1
            runResult2
            checkResult1
            checkResult2
            firstOut
            secondOut
            ;
        };
    in
    {
      _type = "hullJudger";

      # This function generates the standard answer files using the main correct solution.
      generateOutputs =
        testCase: std:
        let
          # Run the two-phase process for the standard solution.
          # We ensure every step succeeds, otherwise it's a configuration error.
          results = runTwoPhase {
            inherit testCase;
            solution = std;
            ensureAccepted = true;
            performCheck = false;
          };
        in
        {
          # The standard answers are the outputs from the two phases.
          first = results.firstOut;
          second = results.secondOut;
        };

      # This function judges a user's solution against a test case.
      judge =
        testCase: solution:
        let
          # Run the two-phase process for the user's solution.
          # We don't ensure acceptance here; instead, we check the status report.
          results = runTwoPhase {
            inherit testCase solution;
            ensureAccepted = false;
            performCheck = true;
          };

          # Helper to create a failing result structure.
          failResult = status: message: {
            inherit status message;
            score = 0.0;
            tick = 0;
            memory = 0;
            outputs = {
              first = results.firstOut;
              second = results.secondOut;
            };
          };
        in
        # Determine the final result based on the outcome of each step.
        if results.runResult1.report.status != "accepted" then
          failResult results.runResult1.report.status results.runResult1.report.errorMessage
        else if results.checkResult1.score == 0.0 then
          failResult results.checkResult1.status results.checkResult1.message
        else if results.runResult2.report.status != "accepted" then
          failResult results.runResult2.report.status results.runResult2.report.errorMessage
        else if results.checkResult2.score == 0.0 then
          failResult results.checkResult2.status results.checkResult2.message
        else
          # If all steps passed, the final score is determined by the first check.
          {
            status = results.checkResult1.status;
            score = results.checkResult1.score;
            message = results.checkResult1.message;
            # Resource usage is the maximum of the two runs.
            tick = lib.max results.runResult1.report.tick results.runResult2.report.tick;
            memory = lib.max results.runResult1.report.memory results.runResult2.report.memory;
            outputs = {
              first = results.firstOut;
              second = results.secondOut;
            };
          };
    };
}
