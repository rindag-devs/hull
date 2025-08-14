{
  hull,
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
    testCase:
    let
      runResult = hull.judge.run problem testCase mainCorrectSolution;
    in
    if runResult.report.status == "accepted" then
      runResult.stdout
    else
      throw "Output generation for problem `${problem.name}`, "
      + "test case `${testCase.name}` failed: "
      + "main correct solution runs unaccepted, report: ${runResult.report}";
in
{
  inherit input output;
}
