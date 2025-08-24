/*
  This file is part of Hull.

  Hull is free software: you can redistribute it and/or modify it under the terms of the GNU
  Lesser General Public License as published by the Free Software Foundation, either version 3 of
  the License, or (at your option) any later version.

  Hull is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
  the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser
  General Public License for more details.

  You should have received a copy of the GNU Lesser General Public License along with Hull. If
  not, see <https://www.gnu.org/licenses/>.
*/

{
  typixLib,
  lib,
  ...
}:

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
          test-cases = lib.mapAttrs (
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
          samples = lib.mapAttrsToList (
            _:
            { data, ... }:
            {
              input = builtins.readFile data.input;
              outputs = lib.mapAttrs (fileName: _: builtins.readFile (data.outputs + "/" + fileName)) (
                builtins.readDir data.outputs
              );
            }
          ) (lib.filterAttrs (_: { groups, ... }: builtins.elem "sample" groups) testCases);
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
          solutions = lib.mapAttrs (
            solName:
            {
              mainCorrectSolution,
              testCaseResults,
              subtaskResults,
              ...
            }:
            {
              main-correct-solution = mainCorrectSolution;
              test-case-results = lib.mapAttrs (
                _:
                {
                  score,
                  status,
                  tick,
                  memory,
                  message,
                  ...
                }:
                {
                  inherit
                    score
                    status
                    tick
                    memory
                    message
                    ;
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
      inputList = lib.mapAttrsToList (
        name: value: "${lib.escapeShellArg name}=${lib.escapeShellArg value}"
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
