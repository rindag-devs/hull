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
      fullScore,
      solutions,
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
      generatedJSONName = "hull-typst-json-${name}.json";
      generatedJSON = builtins.toFile generatedJSONName (
        builtins.toJSON {
          inherit name traits;
          display-name = displayName;
          tick-limit = tickLimit;
          memory-limit = memoryLimit;
          full-score = fullScore;
          test-cases = pkgs.lib.mapAttrs (
            _:
            {
              generator,
              arguments,
              tickLimit,
              memoryLimit,
              groups,
              inputValidation,
              ...
            }:
            {
              inherit generator arguments groups;
              tick-limit = tickLimit;
              memory-limit = memoryLimit;
              actual-traits = inputValidation.traits;
            }
          ) testCases;
          samples = pkgs.lib.mapAttrsToList (
            _: { data, ... }: pkgs.lib.mapAttrs (_: file: builtins.readFile file) data
          ) (pkgs.lib.filterAttrs (_: { groups, ... }: builtins.elem "sample" groups) testCases);
          subtasks = map (
            {
              traits,
              fullScore,
              testCases,
              ...
            }:
            {
              inherit traits;
              full-score = fullScore;
              test-cases = map ({ name, ... }: name) testCases;
            }
          ) subtasks;
          solutions = pkgs.lib.mapAttrs (
            solName:
            {
              mainCorrectSolution,
              testCaseResults,
              subtaskResults,
              ...
            }:
            {
              main-correct-solution = mainCorrectSolution;
              test-case-results = pkgs.lib.mapAttrs (
                _:
                { score, status, ... }:
                {
                  inherit score status;
                }
              ) testCaseResults;
              subtask-results = map (
                {
                  rawScore,
                  scaledScore,
                  statuses,
                  ...
                }:
                {
                  inherit statuses;
                  raw-score = rawScore;
                  scaled-score = scaledScore;
                }
              ) subtaskResults;
            }
          ) solutions;
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
        input = inputList ++ [ "hull-generated-json-path=${generatedJSONName}" ];
      };
      virtualPaths = virtualPaths ++ [
        {
          dest = generatedJSONName;
          src = generatedJSON;
        }
      ];
      unstable_typstPackages = typstPackages;
    };
}
