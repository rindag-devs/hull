{
  pkgs,
  hullPkgs,
}:

let
  input =
    { generators, ... }@problem:
    {
      generatorCwasm,
      arguments,
      inputHash,
      ...
    }@testCase:
    pkgs.runCommandLocal "hull-generated-input-${problem.name}-${testCase.name}"
      {
        nativeBuildInputs = [ hullPkgs.default ];
        outputHash = inputHash;
        outputHashAlgo = null;
      }
      "hull run-wasm ${generatorCwasm} --stdout-path=$out --inherit-stderr -- ${builtins.concatStringsSep " " arguments}";

  output =
    {
      name,
      mainCorrectSolution,
      tickLimit,
      memoryLimit,
      ...
    }:
    { data, name, ... }:
    pkgs.runCommandLocal "hull-generated-output-${name}-${builtins.toString name}"
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
