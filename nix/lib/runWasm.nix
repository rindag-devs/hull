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
  ...
}:

let
  script =
    {
      wasm,
      arguments ? [ ],
      argumentsRaw ? null,
      inputFiles ? { },
      outputFiles ? [ ],
      stdin ? null,
      tickLimit ? null,
      memoryLimit ? null,
      ensureAccepted ? false,
    }:

    let
      mkLimitArg =
        name: limit: lib.optionalString (limit != null) ''--${name}-limit="${toString limit}"'';

      mkFileArg =
        name: files:
        lib.concatMapStringsSep " " (fileName: "--${name}-file ${lib.escapeShellArg fileName}") files;

      stdinArg = lib.optionalString (stdin != null) ''--stdin-path="${stdin}"'';

      tickLimitArg = mkLimitArg "tick" tickLimit;

      memoryLimitArg = mkLimitArg "memory" memoryLimit;

      copyInputFilesCommand = lib.concatMapAttrsStringSep "\n" (
        name: file: ''cp "${file}" ${lib.escapeShellArg name}''
      ) inputFiles;

      copyOutputFilesCommand = lib.concatMapStringsSep "\n" (
        name: ''cp ${lib.escapeShellArg name} "$output_dir/outputFiles/"''
      ) outputFiles;

      # --read-file a.txt --read-file b.txt ...
      inputFileArg = mkFileArg "read" (builtins.attrNames inputFiles);

      # --write-file a.txt --write-file b.txt ...
      outputFileArg = mkFileArg "write" outputFiles;

      ensureAcceptedArg = lib.optionalString ensureAccepted "--ensure-accepted";

      argumentsArg =
        if argumentsRaw != null then
          "-- ${argumentsRaw}"
        else
          lib.optionalString (arguments != [ ]) "-- ${lib.escapeShellArgs arguments}";
    in
    ''
      (
        output_dir=$PWD
        workdir=$(mktemp -d)
        trap 'rm -rf "$workdir"' EXIT

        mkdir -p "$output_dir/outputFiles"
        cd "$workdir"

        ${copyInputFilesCommand}

        ${lib.getExe hullPkgs.default} run-wasm "${wasm}" \
          ${stdinArg} --stdout-path="$output_dir/stdout" --stderr-path="$output_dir/stderr" \
          ${tickLimitArg} ${memoryLimitArg} ${inputFileArg} ${outputFileArg} ${ensureAcceptedArg} \
          --report-path="$output_dir/report.json" \
          ${argumentsArg}

        ${copyOutputFilesCommand}
      )
    '';
in
{
  inherit script;
}
