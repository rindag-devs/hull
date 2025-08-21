{
  hull,
  pkgs,
  ...
}:

# Runs a CPLib checker and return its report
{
  problemName,
  testCaseName,
  solutionName,
  checkerWasm,
  input,
  output,
  answer,
}:
let
  runResult = hull.runWasm {
    name = "hull-check-${problemName}-${testCaseName}-${solutionName}";
    arguments = [
      "input"
      "output"
      "answer"
    ];
    wasm = checkerWasm;
    inputFiles = {
      inherit input output answer;
    };
  };
  checkReport = builtins.fromJSON (builtins.readFile runResult.stderr);
in
{
  inherit (checkReport) status score message;
  readerTraceStacks = checkReport.reader_trace_stacks or [ ];
  evaluatorTraceStacks = checkReport.evaluator_trace_stacks or [ ];
}
