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
    }:
    let
      runChecker = hull.runWasm.script {
        wasm = checkerWasm;
        arguments = [
          "input"
          "output"
          "answer"
        ];
        inputFiles = {
          inherit input output answer;
        };
      };
    in
    ''
      pushd $(mktemp -d) > /dev/null
      ${runChecker}
      ${lib.getExe pkgs.jq} -c \
        '{ status: .status, score: .score, message: .message, readerTraceStacks: (.reader_trace_stacks // []), evaluatorTraceStacks: (.evaluator_trace_stacks // []) }' \
        stderr > "''${DIRSTACK[1]}/check.json"
      popd > /dev/null
    '';

  drv =
    {
      name,
      checkerWasm,
      input,
      output,
      answer,
    }:
    let
      checkScript = script {
        inherit
          checkerWasm
          input
          output
          answer
          ;
      };
    in
    pkgs.runCommandLocal "hull-check-${name}" { } ''
      ${checkScript}
      install -Tm644 check.json $out
    '';
in
{
  inherit script drv;
}
