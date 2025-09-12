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

{ lib, pkgs }:

# A simple contest target builds a specific problem target for each problem and puts it into the
# corresponding subdirectory.
{
  # Name of problem target.
  problemTarget ? "default",
}:
{
  _type = "hullContestTarget";
  __functor =
    self:
    {
      name,
      problems,
      ...
    }:
    let
      copyProblemsCommand = lib.concatMapStringsSep "\n" (
        p: "cp -r ${p.config.targetOutputs.${problemTarget}} $out/${p.config.name}"
      ) problems;
    in
    pkgs.runCommandLocal "hull-contestTargetOutput-${name}-common" { } ''
      mkdir $out
      ${copyProblemsCommand}
    '';
}
