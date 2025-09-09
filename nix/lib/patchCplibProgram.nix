{ pkgs, lib, ... }:

{
  problemName,
  src,
  checker ? null,
  interactor ? null,
  validator ? null,
  extraIncludes ? [ ],
  extraEmbeds ? [ ],
}:
let
  extraIncludesCommand = lib.concatMapStringsSep "\n" (
    h: "echo '#include' ${lib.escapeShellArg h} >> $out"
  ) extraIncludes;
  extraEmbedCommand = lib.concatMapStringsSep "\n" (h: "cat ${h} >> $out") extraEmbeds;
in
pkgs.runCommandLocal "hull-patchCplibProgram-${problemName}-${baseNameOf src}" { } ''
  ${lib.optionalString (
    checker != null
  ) "echo '#define' CPLIB_CHECKER_DEFAULT_INITIALIZER ${lib.escapeShellArg checker} >> $out"}
  ${lib.optionalString (
    interactor != null
  ) "echo '#define' CPLIB_INTERACTOR_DEFAULT_INITIALIZER ${lib.escapeShellArg interactor} >> $out"}
  ${lib.optionalString (
    validator != null
  ) "echo '#define' CPLIB_VALIDATOR_DEFAULT_INITIALIZER ${lib.escapeShellArg validator} >> $out"}
  ${extraEmbedCommand}
  ${extraIncludesCommand}
  cat ${src} >> $out
''
