{
  pkgs,
  hullPkgs,
}:

let
  input =
    { name, generators, ... }:
    {
      generatorCwasm,
      arguments,
      inputHash,
      ...
    }:
    pkgs.runCommandLocal "hull-generated-input-${name}"
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
    { data, ... }:
    pkgs.runCommandLocal "hull-generated-output-${name}" { nativeBuildInputs = [ hullPkgs.default ]; }
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
