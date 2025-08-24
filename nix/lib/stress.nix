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
  lib,
  pkgs,
  hull,
  ...
}:

# The evaluated problem config
problem:
{
  testSolNames,
  stdName,
  generatorName,
  # list of list, contains multiple test cases, each test case contains a generator arguments list
  generatorArgs,
  tickLimit,
  memoryLimit,
}:
let
  # Determine the standard solution
  stdSol =
    if stdName != null then
      problem.solutions.${stdName}
        or (throw "Standard solution '${stdName}' not found in problem.solutions")
    else
      problem.mainCorrectSolution;

  # Get all solutions to be tested
  testSols = map (
    name: problem.solutions.${name} or (throw "Test solution '${name}' not found in problem.solutions")
  ) testSolNames;

  generator =
    problem.generators.${generatorName}
      or (throw "Generator '${generatorName}' not found in problem.generators");

  # Create a list of derivations for judging each case for each solution
  judgeResultsPerCase = lib.imap0 (
    i: args:
    let
      tcName = "stress-${toString i}";

      # Override limits for the fake test case if provided
      finalTickLimit = if tickLimit != null then tickLimit else problem.tickLimit;
      finalMemoryLimit = if memoryLimit != null then memoryLimit else problem.memoryLimit;

      generatedInput = hull.generate.input problem {
        name = "stressInput-${tcName}";
        generatorCwasm = generator.cwasm;
        arguments = args;
      };

      fakeTestCase0 = {
        name = tcName;
        data.input = generatedInput;
        tickLimit = finalTickLimit;
        memoryLimit = finalMemoryLimit;
      };

      fakeTestCase = lib.recursiveUpdate fakeTestCase0 {
        data.outputs = problem.judger.generateOutputs fakeTestCase0 stdSol;
      };
    in
    {
      inherit args;
      testSolutions = map (sol: {
        name = sol.name;
        reportDrv = problem.judger.judge fakeTestCase sol;
      }) testSols;
    }
  ) generatorArgs;

  # Aggregator derivation that analyzes all results
  aggregator =
    let
      passAsJSON = builtins.toJSON (
        map (res: {
          args = res.args;
          testSolutions = map (sol: {
            name = sol.name;
            reportPath = "${sol.reportDrv}/report.json";
          }) res.testSolutions;
        }) judgeResultsPerCase
      );
    in
    pkgs.runCommandLocal "hull-stressAggregator-${problem.name}"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        results_spec=${lib.escapeShellArg passAsJSON}
        hack_case_json="null"

        # Iterate over each generated test case
        while IFS= read -r item_json; do
          # Iterate over each solution for this test case
          while IFS= read -r sol_json; do
            path=$(echo "$sol_json" | jq -r '.reportPath')
            status=$(jq -r '.status' "$path")

            if [[ "$status" != "accepted" ]]; then
              # Found a hack!
              sol_name=$(echo "$sol_json" | jq -r '.name')
              report_json=$(jq -c . "$path")
              
              # Construct the final failing test case JSON
              hack_case_json=$(echo "$item_json" | jq -c \
                --arg sol_name "$sol_name" \
                --argjson report "$report_json" \
                '
                  . + { failingSolutionName: $sol_name, report: $report }
                  | del(.testSolutions)
                ')
              break 2 # Break both loops
            fi
          done < <(echo "$item_json" | jq -c '.testSolutions[]')
        done < <(echo "$results_spec" | jq -c '.[]')

        if [[ "$hack_case_json" != "null" ]]; then
          jq -n --argjson case "$hack_case_json" '{
            "outcome": "hacked",
            "failingTestCase": $case
          }' > $out
          exit 0
        fi

        # If we reach here, all tests passed for all solutions
        echo '{ "outcome": "not_hacked" }' > $out
      '';
in
aggregator
