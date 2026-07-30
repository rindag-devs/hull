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
  pkgs,
  hull,
  ...
}:

let
  script =
    {
      validatorWasm,
      input,
      # 0 = NONE
      # 1 = STACK_ONLY
      # 2 = FULL
      readerTraceLevel ? 1,
    }:
    let
      runScript = hull.runWasm.script {
        request = {
          report_path = "validator-run-report.json";
          files = [
            {
              name = "input";
              kind = "regular";
              host_path = input;
              max_permissions = 4;
              size_limit = "tool";
            }
            {
              name = "validator_stdout";
              kind = "regular";
              host_path = "stdout";
              max_permissions = 2;
              size_limit = "tool";
            }
            {
              name = "validator_stderr";
              kind = "regular";
              host_path = "stderr";
              max_permissions = 2;
              size_limit = "tool";
            }
          ];
          programs = [
            {
              name = "validator";
              wasm_path = toString validatorWasm;
              arguments = [ "--reader-trace-level=${toString readerTraceLevel}" ];
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
                bindings = [ ];
              };
              initial_descriptors = [
                {
                  file = "input";
                  permissions = 4;
                }
                {
                  file = "validator_stdout";
                  permissions = 2;
                }
                {
                  file = "validator_stderr";
                  permissions = 2;
                }
              ];
            }
          ];
        };
      };
    in
    ''
      ${runScript}
      ${pkgs.jq}/bin/jq -c \
        '{ status: .status, message: .message, reader_trace_stacks: (.reader_trace_stacks // []), reader_trace_tree: (.reader_trace_tree // {}), traits: (.traits // {}) }' \
        stderr > validation.json
    '';
in
{
  inherit script;
}
