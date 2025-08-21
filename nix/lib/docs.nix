{
  hull,
  pkgs,
  lib,
  ...
}:

let
  evalOptions = lib.evalModules {
    modules = [
      (_: { _module.check = false; })
      hull.problemModule
    ];
    specialArgs = { inherit hull; };
  };

  optionsDoc = pkgs.nixosOptionsDoc {
    options = builtins.removeAttrs evalOptions.options [ "_module" ];
  };
in
pkgs.runCommandLocal "options-doc.md" { } ''
  cat ${optionsDoc.optionsCommonMark} >> $out
''
