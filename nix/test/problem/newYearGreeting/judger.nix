{
  hull,
  config,
  ...
}:

{
  judger =
    let
      # Compile the transform program once, as it's used in both generateOutputs and judge.
      transformSrc = ./transform.23.cpp;
      transformWasm = hull.compile.executable.drv {
        inherit (config) languages includes;
        src = transformSrc;
        name = "${config.name}-transform";
        extraObjects = [ ];
      };
      solutionRequest = stdinEnvironment: reportPath: stdoutPath: required_accepted: {
        report_path = reportPath;
        files = [
          {
            name = "stdin";
            kind = "regular";
            host_path = hull.runWasm.dynamicString stdinEnvironment;
            max_permissions = 4;
            size_limit = config.fileSizeLimit;
          }
          {
            name = "stdout";
            kind = "regular";
            host_path = stdoutPath;
            max_permissions = 2;
            size_limit = config.fileSizeLimit;
          }
          {
            name = "stderr";
            kind = "regular";
            host_path = null;
            max_permissions = 2;
            size_limit = config.fileSizeLimit;
          }
        ];
        programs = [
          {
            name = "solution";
            wasm_path = hull.runWasm.dynamicString "HULL_SOLUTION_EXECUTABLE";
            arguments = [ ];
            tick_limit = hull.runWasm.dynamicNumber "HULL_TICK_LIMIT";
            memory_limit = hull.runWasm.dynamicNumber "HULL_MEMORY_LIMIT";
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
      transformRequest = inputEnvironment: firstOutEnvironment: reportPath: stdoutPath: {
        report_path = reportPath;
        files = [
          {
            name = "stdin";
            kind = "regular";
            host_path = hull.runWasm.dynamicString inputEnvironment;
            max_permissions = 4;
            size_limit = "tool";
          }
          {
            name = "first_out";
            kind = "regular";
            host_path = hull.runWasm.dynamicString firstOutEnvironment;
            max_permissions = 4;
            size_limit = "tool";
          }
          {
            name = "stdout";
            kind = "regular";
            host_path = stdoutPath;
            max_permissions = 2;
            size_limit = "tool";
          }
          {
            name = "stderr";
            kind = "regular";
            host_path = null;
            max_permissions = 2;
            size_limit = "tool";
          }
        ];
        programs = [
          {
            name = "transform";
            wasm_path = toString transformWasm;
            arguments = [ (hull.runWasm.dynamicString "testCaseNameHashArgument") ];
            tick_limit = "tool";
            memory_limit = "tool";
            required_accepted = true;
            file_system = {
              directories = [
                {
                  path = ".";
                  permissions = 5;
                }
              ];
              bindings = [
                {
                  path = "firstOut";
                  file = "first_out";
                  permissions = 4;
                }
              ];
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
    in
    {
      _type = "hullJudger";

      prepareSolution = hull.judger.writeShellApplication {
        name = "hull-judger-newYearGreeting-prepareSolution-${config.name}";
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
              languages = config.languages;
              srcExpr = ''"$HULL_SOLUTION_SRC"'';
              outExpr = ''"$HULL_PREPARED_SOLUTION_EXECUTABLE_PATH"'';
              includes = config.includes;
              extraObjects = [ ];
            }}
            jq -nc \
              --arg src "$HULL_PREPARED_SOLUTION_SRC_PATH" \
              --arg executable "$HULL_PREPARED_SOLUTION_EXECUTABLE_PATH" \
              '{ src: $src, executable: { path: $executable, drv_path: null } }' > "$HULL_REPORT_PATH"
          '';
      };

      # This function generates the standard answer files using the main correct solution.
      # It writes the output files `first` and `second` into `$HULL_OUTPUTS_DIR`.
      generateOutputs = hull.judger.writeShellApplication {
        name = "hull-judger-newYearGreeting-generateOutputs-${config.name}";
        inheritPath = false;
        runtimeInputs = { targetPkgs, ... }: [ targetPkgs.coreutils ];
        text =
          { targetHull, ... }:
          ''
            testCaseNameHash=$(printf '%s' "$HULL_TESTCASE_NAME" | sha256sum | cut -d' ' -f1)
            testCaseNameHashArgument="--salt=$testCaseNameHash"

            # Phase 1: Run solution to get encoded output
            ${targetHull.runWasm.script {
              request = solutionRequest "HULL_INPUT_PATH" "phase1-report.json" "stdout" true;
            }}
            cp stdout run_stdout1.txt
            echo "0" > firstOut.txt
            cat run_stdout1.txt >> firstOut.txt
            firstOutPath="$PWD/firstOut.txt"

            # Transform: Generate input for phase 2
            ${targetHull.runWasm.script {
              request = transformRequest "HULL_INPUT_PATH" "firstOutPath" "transform-report.json" "stdout";
            }}
            cp stdout secondIn.txt
            secondInPath="$PWD/secondIn.txt"

            # Phase 2: Run solution to get decoded output
            ${targetHull.runWasm.script {
              request = solutionRequest "secondInPath" "phase2-report.json" "stdout" true;
            }}
            cp stdout run_stdout2.txt
            echo "1" > secondOut.txt
            cat run_stdout2.txt >> secondOut.txt

            # Finalize
            mkdir -p "$HULL_OUTPUTS_DIR"
            install -Dm644 firstOut.txt "$HULL_OUTPUTS_DIR/first"
            install -Dm644 secondOut.txt "$HULL_OUTPUTS_DIR/second"
          '';
      };

      # This function judges a user's solution against a test case.
      # It writes `report.json` and generated outputs into the provided paths.
      judge = hull.judger.writeShellApplication {
        name = "hull-judger-newYearGreeting-judge-${config.name}";
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
            testCaseNameHash=$(printf '%s' "$HULL_TESTCASE_NAME" | sha256sum | cut -d' ' -f1)
            testCaseNameHashArgument="--salt=$testCaseNameHash"

            # Phase 1: Run
            ${targetHull.runWasm.script {
              request = solutionRequest "HULL_INPUT_PATH" "report.json" "stdout" false;
            }}
            cp report.json run_report1.json
            cp stdout run_stdout1.txt
            run_report1_path=$PWD/run_report1.json
            run_stdout1_path=$PWD/run_stdout1.txt
            run_status1=$(jq -r '.results[] | select(.program == "solution") | .status' "$run_report1_path")
            if [ "$run_status1" != "accepted" ]; then
              echo "Phase 1 run failed. Status: $run_status1"
              jq -n \
                --arg status "$run_status1" \
                --arg message "$(jq -r '.results[] | select(.program == "solution") | .error_message // ""' "$run_report1_path")" \
                --argjson tick "$(jq '.results[] | select(.program == "solution") | .tick' "$run_report1_path")" \
                --argjson memory "$(jq '.results[] | select(.program == "solution") | .memory' "$run_report1_path")" \
                '{ "status": $status, "score": 0.0, "message": $message, "tick": $tick, "memory": $memory }' > "$HULL_REPORT_PATH"
              exit 0
            fi
            echo "0" > firstOut.txt
            cat "$run_stdout1_path" >> firstOut.txt
            firstOutPath="$PWD/firstOut.txt"
            firstAnswerPath="$HULL_OFFICIAL_OUTPUTS_DIR/first"
            install -Dm644 firstOut.txt "$HULL_OUTPUTS_DIR/first"

            # Phase 1: Check
            ${targetHull.check.script {
              checkerWasm = config.checker.wasm;
              input = targetHull.runWasm.dynamicString "HULL_INPUT_PATH";
              output = targetHull.runWasm.dynamicString "firstOutPath";
              answer = targetHull.runWasm.dynamicString "firstAnswerPath";
              fileSizeLimits = {
                input = "tool";
                output = config.fileSizeLimit;
                answer = "tool";
              };
            }}
            cp check.json check_report1.json
            check_report1_path=$PWD/check_report1.json
            if jq -e '.score == 0' "$check_report1_path" >/dev/null; then
              echo "Phase 1 check failed."
              jq -n \
                --arg status "$(jq -r .status "$check_report1_path")" \
                --arg message "$(jq -r .message "$check_report1_path")" \
                --argjson tick "$(jq '.results[] | select(.program == "solution") | .tick' "$run_report1_path")" \
                --argjson memory "$(jq '.results[] | select(.program == "solution") | .memory' "$run_report1_path")" \
                '{ "status": $status, "score": 0.0, "message": $message, "tick": $tick, "memory": $memory }' > "$HULL_REPORT_PATH"
              exit 0
            fi

            # Transform
            ${targetHull.runWasm.script {
              request = transformRequest "HULL_INPUT_PATH" "firstOutPath" "transform-report.json" "stdout";
            }}
            cp stdout secondIn.txt
            secondInPath="$PWD/secondIn.txt"

            # Validate
            ${targetHull.validate.script {
              validatorWasm = config.validator.wasm;
              input = targetHull.runWasm.dynamicString "secondInPath";
            }}
            cp validation.json validation_report.json
            validation_report_path=$PWD/validation_report.json
            validation_status=$(jq -r .status "$validation_report_path")
            if [ "$validation_status" != "valid" ]; then
              echo "Internal Error: Transform step produced invalid input for phase 2."
              false
            fi

            # Phase 2: Run
            ${targetHull.runWasm.script {
              request = solutionRequest "secondInPath" "report.json" "stdout" false;
            }}
            cp report.json run_report2.json
            cp stdout run_stdout2.txt
            run_report2_path=$PWD/run_report2.json
            run_stdout2_path=$PWD/run_stdout2.txt
            run_status2=$(jq -r '.results[] | select(.program == "solution") | .status' "$run_report2_path")
            if [ "$run_status2" != "accepted" ]; then
              echo "Phase 2 run failed. Status: $run_status2"
              jq -n \
                --arg status "$run_status2" \
                --arg message "$(jq -r '.results[] | select(.program == "solution") | .error_message // ""' "$run_report2_path")" \
                --argjson tick "$(jq '.results[] | select(.program == "solution") | .tick' "$run_report2_path")" \
                --argjson memory "$(jq '.results[] | select(.program == "solution") | .memory' "$run_report2_path")" \
                '{ "status": $status, "score": 0.0, "message": $message, "tick": $tick, "memory": $memory }' > "$HULL_REPORT_PATH"
              exit 0
            fi
            echo "1" > secondOut.txt
            cat "$run_stdout2_path" >> secondOut.txt
            secondOutPath="$PWD/secondOut.txt"
            secondAnswerPath="$HULL_OFFICIAL_OUTPUTS_DIR/second"
            install -Dm644 secondOut.txt "$HULL_OUTPUTS_DIR/second"

            # Phase 2: Check
            ${targetHull.check.script {
              checkerWasm = config.checker.wasm;
              input = targetHull.runWasm.dynamicString "secondInPath";
              output = targetHull.runWasm.dynamicString "secondOutPath";
              answer = targetHull.runWasm.dynamicString "secondAnswerPath";
              fileSizeLimits = {
                input = "tool";
                output = config.fileSizeLimit;
                answer = "tool";
              };
            }}
            cp check.json check_report2.json
            check_report2_path=$PWD/check_report2.json
            if jq -e '.score == 0' "$check_report2_path" >/dev/null; then
              echo "Phase 2 check failed."
              jq -n \
                --arg status "$(jq -r .status "$check_report2_path")" \
                --arg message "$(jq -r .message "$check_report2_path")" \
                --argjson tick "$(jq '.results[] | select(.program == "solution") | .tick' "$run_report2_path")" \
                --argjson memory "$(jq '.results[] | select(.program == "solution") | .memory' "$run_report2_path")" \
                '{ "status": $status, "score": 0.0, "message": $message, "tick": $tick, "memory": $memory }' > "$HULL_REPORT_PATH"
              exit 0
            fi

            # Success
            tick1=$(jq '.results[] | select(.program == "solution") | .tick' "$run_report1_path")
            tick2=$(jq '.results[] | select(.program == "solution") | .tick' "$run_report2_path")
            memory1=$(jq '.results[] | select(.program == "solution") | .memory' "$run_report1_path")
            memory2=$(jq '.results[] | select(.program == "solution") | .memory' "$run_report2_path")
            final_tick=$(( tick1 > tick2 ? tick1 : tick2 ))
            final_memory=$(( memory1 > memory2 ? memory1 : memory2 ))

            jq -n \
              --arg status "$(jq -r .status "$check_report1_path")" \
              --argjson score "$(jq .score "$check_report1_path")" \
              --arg message "$(jq -r .message "$check_report1_path")" \
              --argjson tick "$final_tick" \
              --argjson memory "$final_memory" \
              '{ "status": $status, "score": $score, "message": $message, "tick": $tick, "memory": $memory }' > "$HULL_REPORT_PATH"
          '';
      };
    };
}
