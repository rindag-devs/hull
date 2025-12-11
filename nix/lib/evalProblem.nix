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

# A helper function to evaluate a user's problem definition.
# It takes a user-provided attribute set (the problem definition)
# and evaluates it against our module system.
problemAttrs: extraSpecialArgs:
let
  problem = pkgs.lib.evalModules {
    # The list of modules to evaluate.
    # We have our main problem module and the user's configuration.
    modules = [
      hull.problemModule
      problemAttrs
      (
        { ... }:
        {
          config.problemAttrs = problemAttrs;
          config.extraSpecialArgs = extraSpecialArgs;
        }
      )
    ];

    specialArgs = {
      inherit
        pkgs
        hull
        hullPkgs
        cplib
        ;
    }
    // extraSpecialArgs;
  };
in
problem
