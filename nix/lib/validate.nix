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
  hullPkgs,
  ...
}:

let
  script =
    {
      validatorWasm,
      input,
    }:
    let
      runScript = hull.runWasm.script {
        wasm = validatorWasm;
        stdin = input;
      };
    in
    ''
      pushd $(mktemp -d) > /dev/null
      ${runScript}
      ${pkgs.jq}/bin/jq -c \
        '{ status: .status, message: .message, readerTraceStacks: (.reader_trace_stacks // []), readerTraceTree: (.reader_trace_tree // []), traits: (.traits // {}) }' \
        stderr > "''${DIRSTACK[1]}/validation.json"
      popd > /dev/null
    '';

  drv =
    {
      problemName,
      testCaseName,
      validatorWasm,
      input,
    }:
    let
      validateScript = script { inherit validatorWasm input; };
    in
    pkgs.runCommandLocal "process-validate-${problemName}-${testCaseName}"
      { nativeBuildInputs = [ hullPkgs.default ]; }
      ''
        ${validateScript}
        install -Tm644 validation.json $out
      '';

in
{
  inherit script drv;
}
