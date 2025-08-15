{
  pkgs,
  hullPkgs,
}:

{
  run =
    problem:
    {
      tickLimit,
      memoryLimit,
      data,
      ...
    }@testCase:
    { cwasm, ... }@solution:
    let
      runDerivation =
        pkgs.runCommandLocal "hull-run-${problem.name}-${testCase.name}-${solution.name}"
          { nativeBuildInputs = [ hullPkgs.default ]; }
          ''
            cp ${cwasm} cwasm
            cp ${data.input} stdin
            mkdir $out
            hull run-wasm \
              cwasm \
              --stdin-path=stdin \
              --stdout-path=$out/stdout \
              --stderr-path=$out/stderr \
              --tick-limit=${builtins.toString tickLimit} \
              --memory-limit=${builtins.toString memoryLimit} \
              > $out/report.json \
            || true
          '';
    in
    {
      stdout = runDerivation + "/stdout";
      stderr = runDerivation + "/stderr";
      report = builtins.fromJSON (builtins.readFile (runDerivation + "/report.json"));
    };

  check =
    { checker, ... }@problem:
    { data, ... }@testCase:
    { testCaseResults, ... }@solution:
    let
      runDerivation =
        pkgs.runCommandLocal "hull-check-${problem.name}-${testCase.name}-${solution.name}"
          { nativeBuildInputs = [ hullPkgs.default ]; }
          ''
            cp ${checker.cwasm} cwasm
            cp ${data.input} input
            cp ${testCaseResults.${testCase.name}.run.stdout} output
            cp ${data.output} answer
            hull run-wasm \
              cwasm \
              --inherit-stdout \
              --stderr-path=$out \
              --read-file input \
              --read-file output \
              --read-file answer \
              -- input output answer \
            || true
          '';
    in
    builtins.fromJSON (builtins.readFile runDerivation);

}
