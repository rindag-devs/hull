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
      hash,
      ...
    }:
    pkgs.runCommandLocal "hull-generated-input-${name}" {
      nativeBuildInputs = [ hullPkgs.default ];
      outputHash = hash;
      outputHashAlgo = null;
    } "hull run-wasm ${generatorCwasm} --stdout-path=$out --inherit-stderr";

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

  data = problem: testCase: {
    input = input problem testCase;
    output = output problem testCase;
  };
in
{
  inherit input output data;
}
