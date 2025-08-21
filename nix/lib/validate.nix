{ pkgs, hull, ... }:

{
  problemName,
  testCaseName,
  validatorWasm,
  input,
}:
let
  runResult = hull.runWasm {
    name = "hull-validate-${problemName}-${testCaseName}";
    wasm = validatorWasm;
    stdin = input;
  };
  result = builtins.fromJSON (builtins.readFile runResult.stderr);
in
{
  inherit (result) status message;
  readerTraceStacks = result.reader_trace_stacks or [ ];
  readerTraceTree = result.reader_trace_tree or [ ];
  traits = result.traits or { };
}
