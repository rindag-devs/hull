{ pkgs, hullPkgs }:

{ validator, ... }@problem:
{ data, ... }@testCase:
let
  input = data.input;
  output =
    pkgs.runCommandLocal "hull-validate-${problem.name}-${testCase.name}"
      {
        nativeBuildInputs = [ hullPkgs.default ];
      }
      ''
        cp ${validator.cwasm} cwasm
        hull run-wasm cwasm --stdin-path=${input} --inherit-stdout --stderr-path=$out || true
      '';
  result = builtins.fromJSON (builtins.readFile output);
in
result
