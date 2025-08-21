{
  hull,
  ...
}:

let
  input =
    { generators, ... }@problem:
    { generatorCwasm, arguments, ... }@testCase:
    let
      runResult = hull.runWasm {
        name = "hull-generate-input-${problem.name}-${testCase.name}";
        wasm = generatorCwasm;
        inherit arguments;
        ensureAccepted = true;
      };
      generatedInput = runResult.stdout;
    in
    generatedInput;

  outputs =
    { judger, mainCorrectSolution, ... }: testCase: judger.generateOutputs testCase mainCorrectSolution;
in
{
  inherit input outputs;
}
