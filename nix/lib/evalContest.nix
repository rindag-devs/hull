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
  pkgs,
  hull,
  hullPkgs,
  cplib,
  ...
}:

# A helper function to evaluate a user's contest definition.
# It takes a user-provided attribute set (the contest definition)
# and evaluates it against our module system.
contestAttrs:
let
  contest = pkgs.lib.evalModules {
    # The list of modules to evaluate.
    # We have our main contest module and the user's configuration.
    modules = [
      hull.contestModule
      contestAttrs
    ];

    specialArgs = {
      inherit
        pkgs
        hull
        hullPkgs
        cplib
        ;
    };
  };

  assertions = builtins.concatLists (map (p: p.config.assertions) contest.config.problems);
  warnings = builtins.concatLists (map (p: p.config.warnings) contest.config.problems);
  contestAssertWarn = pkgs.lib.asserts.checkAssertWarn assertions warnings contest;
in
contestAssertWarn
