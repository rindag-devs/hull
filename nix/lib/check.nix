{ pkgs, hullPkgs }:

{ checker, ... }@problem:
{ input, output, ... }@testCase:
let
  output =
    pkgs.runCommandLocal "hull-check-${problem.name}-${testCase.name}"
      {
        nativeBuildInputs = [ hullPkgs.default ];
      }
      "hull run-wasm ${checker.cwasm} --stdin-path=${input} --inherit-stdout --stderr-path=$out || true";
  result = builtins.fromJSON (builtins.readFile output);
in
result
