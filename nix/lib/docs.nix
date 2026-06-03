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
  pkgs,
  lib,
  ...
}:

let
  mkOptionsDoc =
    name: module:
    let
      evalOptions = lib.evalModules {
        modules = [
          (_: { _module.check = false; })
          module
        ];
        specialArgs = { inherit hull; };
      };

      optionsDoc = pkgs.nixosOptionsDoc {
        options = builtins.removeAttrs evalOptions.options [ "_module" ];
        transformOptions = opt: opt // { declarations = [ ]; };
      };
    in
    pkgs.runCommandLocal "hull-${name}-options-doc.md" { } ''
      cat ${optionsDoc.optionsCommonMark} >> $out
    '';
in
{
  options = {
    problemModule = mkOptionsDoc "problem-module" hull.problemModule;
    contestModule = mkOptionsDoc "contest-module" hull.contestModule;
  };
}
