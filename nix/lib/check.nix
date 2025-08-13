{ pkgs, hullPkgs }:

{ name, checker, ... }:
{ input, output, ... }:
let
  output =
    pkgs.runCommandLocal "hull-validate-${name}"
      {
        nativeBuildInputs = [ hullPkgs.default ];
      }
      "hull run-wasm ${checker.cwasm} --stdin-path=${input} --inherit-stdout --stderr-path=$out || true";
  result = builtins.fromJSON (builtins.readFile output);
in
result
