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
  hull,
  ...
}:

let
  input =
    { generators, ... }@problem:
    { generatorCwasm, arguments, ... }@testCase:
    let
      runResult = hull.runWasm {
        name = "hull-generate-input-${problem.name}-${testCase.name}";
        wasm = generatorCwasm;
        inherit arguments;
        ensureAccepted = true;
      };
      generatedInput = runResult.stdout;
    in
    generatedInput;

  outputs =
    { judger, mainCorrectSolution, ... }: testCase: judger.generateOutputs testCase mainCorrectSolution;
in
{
  inherit input outputs;
}
