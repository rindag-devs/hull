{ pkgs, typixLib }:

{
  mkTypstDocument =
    {
      name,
      displayName,
      traits,
      tickLimit,
      memoryLimit,
      testCases,
      subtasks,
      ...
    }:
    {
      src,
      entry ? "main.typ",
      inputs ? { },
      fontPaths ? [ ],
      virtualPaths ? [ ],
      typstPackages ? [ ],
    }:
    let
      generatedJsonName = "hull-typst-json-${name}.json";
      generatedJson = builtins.toFile generatedJsonName (
        builtins.toJSON {
          name = displayName;
          tick-limit = tickLimit;
          memory-limit = memoryLimit;
          samples = pkgs.lib.mapAttrsToList (
            _: { data, ... }: pkgs.lib.mapAttrs (_: file: builtins.readFile file) data
          ) (pkgs.lib.filterAttrs (_: { groups, ... }: builtins.elem "sample" groups) testCases);
          traits = pkgs.lib.mapAttrs (_: { description, ... }: description) traits;
          subtasks = map (
            { traits, fullScore, ... }:
            {
              inherit traits;
              full-score = fullScore;
            }
          ) subtasks;
        }
      );
      inputList = pkgs.lib.mapAttrsToList (
        name: value: "${pkgs.lib.escapeShellArg name}=${pkgs.lib.escapeShellArg value}"
      ) inputs;
    in
    typixLib.buildTypstProject {
      inherit src fontPaths;
      typstSource = entry;
      typstOpts = {
        format = "pdf";
        input = inputList ++ [ "hull-generated-json-path=${generatedJsonName}" ];
      };
      virtualPaths = virtualPaths ++ [
        {
          dest = generatedJsonName;
          src = generatedJson;
        }
      ];
      unstable_typstPackages = typstPackages;
    };
}
