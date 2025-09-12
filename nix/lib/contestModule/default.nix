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
  hull,
  config,
  ...
}:

{
  options = {
    name = lib.mkOption {
      type = hull.types.nameStr;
      description = "The unique name of the contest.";
      example = "exampleProblem";
    };

    displayName = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      description = "Display contest title for each language.";
      example = {
        en = "example contest";
        zh = "示例比赛";
      };
      default = { };
    };

    problems = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      description = "Problems of the contest.";
      apply = map hull.evalProblem;
    };

    targets = lib.mkOption {
      type = lib.types.attrsOf hull.types.contestTarget;
      default = { };
      description = "An attribute set of build targets for the contest, defining final package structures.";
    };

    targetOutputs = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      description = "The final derivation outputs for each defined target.";
      default = builtins.mapAttrs (targetName: target: target config) config.targets;
      defaultText = lib.literalExpression "builtins.mapAttrs (targetName: target: target config) config.targets";
    };
  };
}
