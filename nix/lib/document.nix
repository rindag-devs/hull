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

let
  mkProblemOverview =
    {
      name,
      displayName,
      traits,
      tickLimit,
      memoryLimit,
      fileSizeLimit,
      testCases,
      subtasks,
      fullScore,
      solutions,
      ...
    }:
    {
      inherit name traits;
      display_name = displayName;
      tick_limit = tickLimit;
      memory_limit = memoryLimit;
      file_size_limit = fileSizeLimit;
      full_score = fullScore;
      test_cases = lib.mapAttrs (
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
          tick_limit = tickLimit;
          memory_limit = memoryLimit;
          actual_traits = inputValidation.traits;
        }
      ) testCases;
      # Sample is used to display directly on the document.
      # Therefore, only the "sample" group is filtered, excluding "sampleLarge".
      samples = lib.mapAttrsToList (
        _:
        {
          data,
          inputValidation,
          descriptions,
          ...
        }:
        {
          inherit descriptions;
          input = builtins.readFile data.input;
          outputs = lib.mapAttrs (fileName: _: builtins.readFile (data.outputs + "/" + fileName)) (
            builtins.readDir data.outputs
          );
          input_validation = {
            inherit (inputValidation) status traits;
            reader_trace_stacks = inputValidation.readerTraceStacks;
            reader_trace_tree = inputValidation.readerTraceTree;
          };
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
          full_score = fullScore;
          test_cases = map ({ name, ... }: name) testCases;
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
          main_correct_solution = mainCorrectSolution;
          test_case_results = lib.mapAttrs (
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
          subtask_results = map (
            {
              rawScore,
              scaledScore,
              statuses,
              ...
            }:
            {
              inherit statuses;
              raw_score = rawScore;
              scaled_score = scaledScore;
            }
          ) subtaskResults;
        }
      ) solutions;
    };
in

{
  inherit mkProblemOverview;

  mkProblemTypstDocument =
    problem:
    {
      src,
      entry ? "main.typ",
      inputs ? { },
      fontPaths ? [ ],
      virtualPaths ? [ ],
      typstPackages ? [ ],
    }:
    let
      generatedJSONName = "hull-problemTypstJSON-${problem.name}.json";
      generatedJSON = builtins.toFile generatedJSONName (builtins.toJSON (mkProblemOverview problem));
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

  mkContestTypstDocument =
    contest:
    {
      src,
      entry ? "main.typ",
      inputs ? { },
      fontPaths ? [ ],
      virtualPaths ? [ ],
      typstPackages ? [ ],
    }:
    let
      generatedJSONName = "hull-contestTypstJSON-${contest.name}.json";
      generatedJSON = builtins.toFile generatedJSONName (
        builtins.toJSON {
          inherit (contest) name;
          display_name = contest.displayName;
          problems = map (p: mkProblemOverview p.config) contest.problems;
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
