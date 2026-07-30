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
  hullPkgs,
  lib,
  pkgs,
  ...
}:

let
  markerName = "_hull_run_wasm_dynamic";

  dynamic = type: environment: {
    "${markerName}" = {
      inherit type environment;
    };
  };

  isDynamic = value: builtins.isAttrs value && builtins.hasAttr markerName value;
  collectDynamic =
    path: value:
    if isDynamic value then
      [
        {
          inherit path;
          inherit (value.${markerName}) type environment;
        }
      ]
    else if builtins.isList value then
      lib.concatLists (lib.imap0 (index: collectDynamic (path ++ [ index ])) value)
    else if builtins.isAttrs value then
      lib.concatLists (lib.mapAttrsToList (name: collectDynamic (path ++ [ name ])) value)
    else
      [ ];

  eraseDynamic =
    value:
    if isDynamic value then
      null
    else if builtins.isList value then
      map eraseDynamic value
    else if builtins.isAttrs value then
      lib.mapAttrs (_: eraseDynamic) value
    else
      value;

  script =
    { request }:
    let
      substitutions = collectDynamic [ ] request;
      template = pkgs.writeText "run-wasm-request-template.json" (builtins.toJSON (eraseDynamic request));
      applySubstitution =
        index:
        {
          path,
          type,
          environment,
        }:
        let
          input = if index == 0 then template else "$PWD/.run-wasm-request-${toString index}.json";
          output = "$PWD/.run-wasm-request-${toString (index + 1)}.json";
          environmentReference = "$" + "{" + environment + "}";
          jqArgument =
            if type == "string" then
              "--arg value \"${environmentReference}\""
            else if type == "number" then
              "--argjson value \"${environmentReference}\""
            else
              throw "unsupported run-wasm dynamic scalar type `${type}`";
        in
        ''
          ${lib.getExe pkgs.jq} ${jqArgument} \
            ${lib.escapeShellArg "setpath(${builtins.toJSON path}; $value)"} \
            "${input}" > "${output}"
        '';
      substitutionsScript = lib.concatImapStrings (index: applySubstitution (index - 1)) substitutions;
      finalRequest =
        if substitutions == [ ] then
          template
        else
          "$PWD/.run-wasm-request-${toString (builtins.length substitutions)}.json";
    in
    ''
      ${substitutionsScript}
      cp "${finalRequest}" "$PWD/run-wasm-request.json"
      ${lib.getExe hullPkgs.default} run-wasm "$PWD/run-wasm-request.json"
    '';
in
{
  inherit script;

  dynamicString = dynamic "string";
  dynamicNumber = dynamic "number";
}
