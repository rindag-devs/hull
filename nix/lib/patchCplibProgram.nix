{
  pkgs,
  lib,
  hullPkgs,
  ...
}:

{
  problemName,
  src,
  checker ? null,
  interactor ? null,
  validator ? null,
  extraIncludes ? [ ],
  extraEmbeds ? [ ],
  includeReplacements ? [ ],
}:
let
  extraIncludesCommand = lib.concatMapStringsSep "\n" (
    h: "echo '#include' ${lib.escapeShellArg h} >> $out"
  ) extraIncludes;
  extraEmbedCommand = lib.concatMapStringsSep "\n" (h: "cat ${h} >> $out") extraEmbeds;
  includeReplacementCommand = lib.concatMapStringsSep "\n" (r: ''
    ${lib.getExe hullPkgs.default} patch-includes old_src new_src ${lib.escapeShellArgs r}
    mv new_src old_src
  '') includeReplacements;
in
pkgs.runCommandLocal "hull-patchCplibProgram-${problemName}-${baseNameOf src}"
  { nativeBuildInputs = [ hullPkgs.default ]; }
  ''
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

    cp ${src} old_src
    ${includeReplacementCommand}
    cat old_src >> $out
  ''
