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
    in
    {
      _type = "hullJudger";

      # This function generates the standard answer files using the main correct solution.
      # It returns a derivation containing the output files `first` and `second`.
      generateOutputs =
        testCase: std:
        let
          # Compile the standard solution.
          solutionWasm = hull.compile.executable {
            inherit (config) languages includes;
            src = std.src;
            name = "${config.name}-solution-${std.name}";
            extraObjects = [ ];
          };
          solutionCwasm = hull.compile.cwasm {
            name = "${config.name}-solution-${std.name}";
            wasm = solutionWasm;
          };
        in
        pkgs.runCommandLocal "hull-generateOutputs-${config.name}-${testCase.name}" { } ''
          # --- Phase 1: Run solution to get encoded output ---
          ${hull.runWasm.script {
            wasm = solutionCwasm;
            stdin = testCase.data.input;
            tickLimit = testCase.tickLimit;
            memoryLimit = testCase.memoryLimit;
            ensureAccepted = true;
          }}
          cp stdout run_stdout1.txt
          echo "0" > firstOut.txt
          cat run_stdout1.txt >> firstOut.txt

          # --- Transform: Generate input for phase 2 ---
          ${hull.runWasm.script {
            wasm = transformCwasm;
            arguments = [ "--salt=${builtins.hashString "sha256" testCase.name}" ];
            stdin = testCase.data.input;
            inputFiles = {
              firstOut = "$output_dir/firstOut.txt";
            };
            ensureAccepted = true;
          }}
          cp stdout secondIn.txt

          # --- Phase 2: Run solution to get decoded output ---
          ${hull.runWasm.script {
            wasm = solutionCwasm;
            stdin = "$output_dir/secondIn.txt";
            tickLimit = testCase.tickLimit;
            memoryLimit = testCase.memoryLimit;
            ensureAccepted = true;
          }}
          cp stdout run_stdout2.txt
          echo "1" > secondOut.txt
          cat run_stdout2.txt >> secondOut.txt

          # --- Finalize ---
          mkdir -p $out
          install -Dm644 firstOut.txt $out/first
          install -Dm644 secondOut.txt $out/second
        '';

      # This function judges a user's solution against a test case.
      # It returns a derivation containing `report.json` and an `outputs` directory.
      judge =
        testCase: solution:
        let
          # Compile the user's solution.
          solutionWasm = hull.compile.executable {
            inherit (config) languages includes;
            src = solution.src;
            name = "${config.name}-solution-${solution.name}";
            extraObjects = [ ];
          };
          solutionCwasm = hull.compile.cwasm {
            name = "${config.name}-solution-${solution.name}";
            wasm = solutionWasm;
          };
        in
        pkgs.runCommandLocal "hull-judge-${config.name}-${testCase.name}-${solution.name}"
          {
            nativeBuildInputs = [
              pkgs.jq
              pkgs.bc
            ];
          }
          ''
            mkdir -p $out/outputs

            # --- Phase 1: Run ---
            ${hull.runWasm.script {
              wasm = solutionCwasm;
              stdin = testCase.data.input;
              tickLimit = testCase.tickLimit;
              memoryLimit = testCase.memoryLimit;
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
                '{ "status": $status, "score": 0.0, "message": $message, "tick": $tick, "memory": $memory }' > $out/report.json
              exit 0
            fi
            echo "0" > firstOut.txt
            cat "$run_stdout1_path" >> firstOut.txt
            install -Dm644 firstOut.txt $out/outputs/first

            # --- Phase 1: Check ---
            ${hull.check.script {
              checkerWasm = config.checker.cwasm;
              input = testCase.data.input;
              output = "$output_dir/firstOut.txt";
              answer = testCase.data.outputs + "/first";
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
                '{ "status": $status, "score": 0.0, "message": $message, "tick": $tick, "memory": $memory }' > $out/report.json
              exit 0
            fi

            # --- Transform ---
            ${hull.runWasm.script {
              wasm = transformCwasm;
              arguments = [ "--salt=${builtins.hashString "sha256" testCase.name}" ];
              stdin = testCase.data.input;
              inputFiles = {
                firstOut = "$output_dir/firstOut.txt";
              };
              ensureAccepted = true;
            }}
            cp stdout secondIn.txt

            # --- Validate ---
            ${hull.validate.script {
              validatorWasm = config.validator.cwasm;
              input = "$output_dir/secondIn.txt";
            }}
            cp validation.json validation_report.json
            validation_report_path=$PWD/validation_report.json
            validation_status=$(jq -r .status "$validation_report_path")
            if [ "$validation_status" != "valid" ]; then
              echo "Internal Error: Transform step produced invalid input for phase 2."
              false
            fi

            # --- Phase 2: Run ---
            ${hull.runWasm.script {
              wasm = solutionCwasm;
              stdin = "$output_dir/secondIn.txt";
              tickLimit = testCase.tickLimit;
              memoryLimit = testCase.memoryLimit;
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
                '{ "status": $status, "score": 0.0, "message": $message, "tick": $tick, "memory": $memory }' > $out/report.json
              exit 0
            fi
            echo "1" > secondOut.txt
            cat "$run_stdout2_path" >> secondOut.txt
            install -Dm644 secondOut.txt $out/outputs/second

            # --- Phase 2: Check ---
            ${hull.check.script {
              checkerWasm = config.checker.cwasm;
              input = "$output_dir/secondIn.txt";
              output = "$output_dir/secondOut.txt";
              answer = testCase.data.outputs + "/second";
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
                '{ "status": $status, "score": 0.0, "message": $message, "tick": $tick, "memory": $memory }' > $out/report.json
              exit 0
            fi

            # --- Success ---
            echo "All phases successful."
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
              '{ "status": $status, "score": $score, "message": $message, "tick": $tick, "memory": $memory }' > $out/report.json
          '';
    };
}
