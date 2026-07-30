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
  hull,
  pkgs,
  lib,
  ...
}:

# Runs a CPLib checker and return its report
let
  # Generate a bash script to run the checker, outputs a `check.json` to the current directory
  script =
    {
      checkerWasm,
      input,
      output,
      answer,
      fileSizeLimits,
    }:
    let
      runChecker = hull.runWasm.script {
        request = {
          report_path = "checker-run-report.json";
          files =
            map
              (name: {
                inherit name;
                kind = "regular";
                host_path = { inherit input output answer; }.${name};
                max_permissions = 4;
                size_limit = fileSizeLimits.${name};
              })
              [
                "input"
                "output"
                "answer"
              ]
            ++ [
              {
                name = "checker_stdout";
                kind = "regular";
                host_path = "checker.stdout";
                max_permissions = 2;
                size_limit = "tool";
              }
              {
                name = "checker_stderr";
                kind = "regular";
                host_path = "checker.stderr";
                max_permissions = 2;
                size_limit = "tool";
              }
            ];
          programs = [
            {
              name = "checker";
              wasm_path = toString checkerWasm;
              arguments = [
                "input"
                "output"
                "answer"
              ];
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
                bindings =
                  map
                    (name: {
                      path = name;
                      file = name;
                      permissions = 4;
                    })
                    [
                      "input"
                      "output"
                      "answer"
                    ];
              };
              initial_descriptors = [
                {
                  file = null;
                  permissions = 0;
                }
                {
                  file = "checker_stdout";
                  permissions = 2;
                }
                {
                  file = "checker_stderr";
                  permissions = 2;
                }
              ];
            }
          ];
        };
      };
    in
    ''
      ${runChecker}
      checker_status=$(${lib.getExe pkgs.jq} -r \
        '.results[] | select(.program == "checker") | .status' checker-run-report.json)
      if [ "$checker_status" = file_error ]; then
        ${lib.getExe pkgs.jq} -c \
          '.results[] | select(.program == "checker") | {
            status: .status,
            score: 0.0,
            message: (.error_message // "File size limit exceeded"),
            reader_trace_stacks: [],
            evaluator_trace_stacks: []
          }' checker-run-report.json > check.json
      else
        ${lib.getExe pkgs.jq} -e \
          '.results == [(.results[0] | select(.program == "checker" and (.status == "accepted" or (.status == "runtime_error" and .exit_code != null))))]' \
          checker-run-report.json > /dev/null
        ${lib.getExe pkgs.jq} -c \
          '{ status: .status, score: .score, message: .message, reader_trace_stacks: (.reader_trace_stacks // []), evaluator_trace_stacks: (.evaluator_trace_stacks // []) }' \
          checker.stderr > check.json
      fi
    '';
in
{
  inherit script;
}
