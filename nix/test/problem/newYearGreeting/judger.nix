{
  hull,
  config,
  pkgs,
  ...
}:

{
  judger =
    let
      # Compile the transform program once, as it's used in both generateOutputs and judge.
      transformSrc = ./transform.20.cpp;
      transformWasm = hull.compile.executable.drv {
        inherit (config) languages includes;
        src = transformSrc;
        name = "${config.name}-transform";
        extraObjects = [ ];
      };
      compileExecutableScript = hull.compile.executableMatchScript {
        languages = config.languages;
        srcExpr = ''"$HULL_SOLUTION_SRC"'';
        outExpr = ''"$HULL_PREPARED_SOLUTION_EXECUTABLE_PATH"'';
        includes = config.includes;
        extraObjects = [ ];
      };
    in
    {
      _type = "hullJudger";

      prepareSolution = pkgs.writeShellApplication {
        name = "hull-judger-newYearGreeting-prepareSolution-${config.name}";
        inheritPath = false;
        runtimeInputs = [
          pkgs.coreutils
          pkgs.jq
        ];
        text = ''
          cp "$HULL_SOLUTION_SRC" "$HULL_PREPARED_SOLUTION_SRC_PATH"
          ${compileExecutableScript}
          jq -nc \
            --arg src "$HULL_PREPARED_SOLUTION_SRC_PATH" \
            --arg executable "$HULL_PREPARED_SOLUTION_EXECUTABLE_PATH" \
            '{ src: $src, executable: { path: $executable, drvPath: null } }' > "$HULL_REPORT_PATH"
        '';
      };

      # This function generates the standard answer files using the main correct solution.
      # It writes the output files `first` and `second` into `$HULL_OUTPUTS_DIR`.
      generateOutputs = pkgs.writeShellApplication {
        name = "hull-judger-newYearGreeting-generateOutputs-${config.name}";
        inheritPath = false;
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          testCaseNameHash=$(printf '%s' "$HULL_TESTCASE_NAME" | sha256sum | cut -d' ' -f1)

          # Phase 1: Run solution to get encoded output
          ${hull.runWasm.script {
            wasm = "$HULL_SOLUTION_EXECUTABLE";
            stdin = "$HULL_INPUT_PATH";
            tickLimit = "$HULL_TICK_LIMIT";
            memoryLimit = "$HULL_MEMORY_LIMIT";
            ensureAccepted = true;
          }}
          cp stdout run_stdout1.txt
          echo "0" > firstOut.txt
          cat run_stdout1.txt >> firstOut.txt

          # Transform: Generate input for phase 2
          ${hull.runWasm.script {
            wasm = transformWasm;
            argumentsRaw = ''"--salt=$testCaseNameHash"'';
            stdin = "$HULL_INPUT_PATH";
            inputFiles = {
              firstOut = "$output_dir/firstOut.txt";
            };
            ensureAccepted = true;
          }}
          cp stdout secondIn.txt

          # Phase 2: Run solution to get decoded output
          ${hull.runWasm.script {
            wasm = "$HULL_SOLUTION_EXECUTABLE";
            stdin = "$output_dir/secondIn.txt";
            tickLimit = "$HULL_TICK_LIMIT";
            memoryLimit = "$HULL_MEMORY_LIMIT";
            ensureAccepted = true;
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
      judge = pkgs.writeShellApplication {
        name = "hull-judger-newYearGreeting-judge-${config.name}";
        inheritPath = false;
        runtimeInputs = [
          pkgs.bc
          pkgs.coreutils
          pkgs.jq
        ];
        text = ''
          testCaseNameHash=$(printf '%s' "$HULL_TESTCASE_NAME" | sha256sum | cut -d' ' -f1)

          # Phase 1: Run
          ${hull.runWasm.script {
            wasm = "$HULL_SOLUTION_EXECUTABLE";
            stdin = "$HULL_INPUT_PATH";
            tickLimit = "$HULL_TICK_LIMIT";
            memoryLimit = "$HULL_MEMORY_LIMIT";
            ensureAccepted = false;
          }}
          cp report.json run_report1.json
          cp stdout run_stdout1.txt
          run_report1_path=$PWD/run_report1.json
          run_stdout1_path=$PWD/run_stdout1.txt
          run_status1=$(jq -r .status "$run_report1_path")
          if [ "$run_status1" != "accepted" ]; then
            echo "Phase 1 run failed. Status: $run_status1"
            jq -n \
              --arg status "$run_status1" \
              --arg message "$(jq -r .errorMessage "$run_report1_path")" \
              --argjson tick "$(jq .tick "$run_report1_path")" \
              --argjson memory "$(jq .memory "$run_report1_path")" \
              '{ "status": $status, "score": 0.0, "message": $message, "tick": $tick, "memory": $memory }' > "$HULL_REPORT_PATH"
            exit 0
          fi
          echo "0" > firstOut.txt
          cat "$run_stdout1_path" >> firstOut.txt
          install -Dm644 firstOut.txt "$HULL_OUTPUTS_DIR/first"

          # Phase 1: Check
          ${hull.check.script {
            checkerWasm = config.checker.wasm;
            input = "$HULL_INPUT_PATH";
            output = "$output_dir/firstOut.txt";
            answer = "$HULL_OFFICIAL_OUTPUTS_DIR/first";
          }}
          cp check.json check_report1.json
          check_report1_path=$PWD/check_report1.json
          check_score1=$(jq -r .score "$check_report1_path")
          if [ "$(echo "$check_score1 == 0.0" | bc)" -eq 1 ]; then
            echo "Phase 1 check failed."
            jq -n \
              --arg status "$(jq -r .status "$check_report1_path")" \
              --arg message "$(jq -r .message "$check_report1_path")" \
              --argjson tick "$(jq .tick "$run_report1_path")" \
              --argjson memory "$(jq .memory "$run_report1_path")" \
              '{ "status": $status, "score": 0.0, "message": $message, "tick": $tick, "memory": $memory }' > "$HULL_REPORT_PATH"
            exit 0
          fi

            # Transform
            ${hull.runWasm.script {
              wasm = transformWasm;
              argumentsRaw = ''"--salt=$testCaseNameHash"'';
              stdin = "$HULL_INPUT_PATH";
              inputFiles = {
                firstOut = "$output_dir/firstOut.txt";
              };
              ensureAccepted = true;
            }}
          cp stdout secondIn.txt

          # Validate
          ${hull.validate.script {
            validatorWasm = config.validator.wasm;
            input = "$output_dir/secondIn.txt";
          }}
          cp validation.json validation_report.json
          validation_report_path=$PWD/validation_report.json
          validation_status=$(jq -r .status "$validation_report_path")
          if [ "$validation_status" != "valid" ]; then
            echo "Internal Error: Transform step produced invalid input for phase 2."
            false
          fi

          # Phase 2: Run
          ${hull.runWasm.script {
            wasm = "$HULL_SOLUTION_EXECUTABLE";
            stdin = "$output_dir/secondIn.txt";
            tickLimit = "$HULL_TICK_LIMIT";
            memoryLimit = "$HULL_MEMORY_LIMIT";
            ensureAccepted = false;
          }}
          cp report.json run_report2.json
          cp stdout run_stdout2.txt
          run_report2_path=$PWD/run_report2.json
          run_stdout2_path=$PWD/run_stdout2.txt
          run_status2=$(jq -r .status "$run_report2_path")
          if [ "$run_status2" != "accepted" ]; then
            echo "Phase 2 run failed. Status: $run_status2"
            jq -n \
              --arg status "$run_status2" \
              --arg message "$(jq -r .errorMessage "$run_report2_path")" \
              --argjson tick "$(jq .tick "$run_report2_path")" \
              --argjson memory "$(jq .memory "$run_report2_path")" \
              '{ "status": $status, "score": 0.0, "message": $message, "tick": $tick, "memory": $memory }' > "$HULL_REPORT_PATH"
            exit 0
          fi
          echo "1" > secondOut.txt
          cat "$run_stdout2_path" >> secondOut.txt
          install -Dm644 secondOut.txt "$HULL_OUTPUTS_DIR/second"

          # Phase 2: Check
          ${hull.check.script {
            checkerWasm = config.checker.wasm;
            input = "$output_dir/secondIn.txt";
            output = "$output_dir/secondOut.txt";
            answer = "$HULL_OFFICIAL_OUTPUTS_DIR/second";
          }}
          cp check.json check_report2.json
          check_report2_path=$PWD/check_report2.json
          check_score2=$(jq -r .score "$check_report2_path")
          if [ "$(echo "$check_score2 == 0.0" | bc)" -eq 1 ]; then
            echo "Phase 2 check failed."
            jq -n \
              --arg status "$(jq -r .status "$check_report2_path")" \
              --arg message "$(jq -r .message "$check_report2_path")" \
              --argjson tick "$(jq .tick "$run_report2_path")" \
              --argjson memory "$(jq .memory "$run_report2_path")" \
              '{ "status": $status, "score": 0.0, "message": $message, "tick": $tick, "memory": $memory }' > "$HULL_REPORT_PATH"
            exit 0
          fi

          # Success
          tick1=$(jq .tick "$run_report1_path")
          tick2=$(jq .tick "$run_report2_path")
          memory1=$(jq .memory "$run_report1_path")
          memory2=$(jq .memory "$run_report2_path")
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
