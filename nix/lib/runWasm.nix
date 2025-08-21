{
  pkgs,
  hullPkgs,
  lib,
  ...
}:

{
  name,
  wasm,
  arguments ? [ ],
  inputFiles ? { },
  outputFiles ? [ ],
  stdin ? null,
  tickLimit ? null,
  memoryLimit ? null,
  ensureAccepted ? false,
}:
let
  mkLimitArg = name: limit: lib.optionalString (limit != null) "--${name}-limit=${toString limit}";
  mkFileArg =
    name: files:
    lib.concatMapStringsSep " " (fileName: "--${name}-file ${lib.escapeShellArg fileName}") files;
  stdinArg = lib.optionalString (stdin != null) "--stdin-path=${stdin}";
  tickLimitArg = mkLimitArg "tick" tickLimit;
  memoryLimitArg = mkLimitArg "memory" memoryLimit;
  copyInputFilesCommand = lib.concatMapAttrsStringSep "\n" (
    name: file: "cp ${file} ${lib.escapeShellArg name}"
  ) inputFiles;
  copyOutputFilesCommand = lib.concatMapStringsSep "\n" (
    name: "cp ${lib.escapeShellArg name} $out/files/"
  ) outputFiles;
  inputFileArg = mkFileArg "read" (builtins.attrNames inputFiles);
  outputFileArg = mkFileArg "write" outputFiles;
  runDerivation = pkgs.runCommandLocal name { nativeBuildInputs = [ hullPkgs.default ]; } ''
    mkdir -p $out/files
    ${copyInputFilesCommand}
    hull run-wasm ${wasm} ${stdinArg} --stdout-path=$out/stdout --stderr-path=$out/stderr \
      ${tickLimitArg} ${memoryLimitArg} ${inputFileArg} ${outputFileArg} --report-path=$out/report.json \
      -- ${lib.escapeShellArgs arguments}
    ${copyOutputFilesCommand}
  '';
  report = builtins.fromJSON (builtins.readFile "${runDerivation}/report.json");
in
if ensureAccepted && report.status != "accepted" then
  throw "${name} returns an unaccepted status, report: ${builtins.toJSON report}, derivation output: ${runDerivation}"
else
  {
    inherit report;
    stdout = runDerivation + "/stdout";
    stderr = runDerivation + "/stderr";
    outputFiles = builtins.listToAttrs map (name: {
      inherit name;
      value = outputFiles runDerivation + "/files/${name}";
    });
  }
