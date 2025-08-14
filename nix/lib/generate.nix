{
  pkgs,
  hullPkgs,
}:

let
  input =
    { generators, ... }@problem:
    { generatorCwasm, arguments, ... }@testCase:
    pkgs.runCommandLocal "hull-generated-input-${problem.name}-${testCase.name}"
      { nativeBuildInputs = [ hullPkgs.default ]; }
      "hull run-wasm ${generatorCwasm} --stdout-path=$out --inherit-stderr -- ${pkgs.lib.escapeShellArgs arguments}";

  output =
    { mainCorrectSolution, ... }@problem:
    {
      data,
      tickLimit,
      memoryLimit,
      ...
    }@testCase:
    pkgs.runCommandLocal "hull-generated-output-${problem.name}-${testCase.name}"
      { nativeBuildInputs = [ hullPkgs.default ]; }
      ''
        hull run-wasm \
          ${mainCorrectSolution.cwasm} \
          --stdin-path=${data.input} \
          --stdout-path=$out \
          --inherit-stderr \
          --tick-limit=${builtins.toString tickLimit} \
          --memory-limit=${builtins.toString memoryLimit}
      '';
in
{
  inherit input output;
}
