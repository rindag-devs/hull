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
  lib,
  cplib,
  cplibInitializers,
  ...
}:

{
  cms = import ./cms.nix {
    inherit
      lib
      hull
      pkgs
      cplib
      cplibInitializers
      ;
  };

  common = import ./common.nix {
    inherit
      lib
      hull
      pkgs
      ;
  };

  domjudge = import ./domjudge.nix {
    inherit
      lib
      hull
      pkgs
      cplib
      cplibInitializers
      ;
  };

  hydro = import ./hydro.nix {
    inherit
      lib
      hull
      pkgs
      cplib
      cplibInitializers
      ;
  };

  lemon = import ./lemon.nix {
    inherit
      lib
      hull
      pkgs
      cplib
      cplibInitializers
      ;
  };

  luogu = import ./luogu {
    inherit
      lib
      hull
      pkgs
      cplib
      cplibInitializers
      ;
  };

  uoj = import ./uoj.nix {
    inherit
      lib
      hull
      pkgs
      cplib
      cplibInitializers
      ;
  };

  utils =

    let
      makeProgramItem =
        name: program:
        if program.participantVisibility == "src" then
          { "${name}.${hull.language.toFileExtension program.language}" = program.src; }
        else if program.participantVisibility == "wasm" then
          { "${name}.wasm" = program.wasm; }
        else
          { };
    in
    {
      # Shell command to copy participant-visible programs, using flattened directory structure.
      participantProgramsCommand =
        {
          problem,
          dest,
          flattened,
        }:
        let
          visiblePrograms =
            (makeProgramItem "checker" problem.checker)
            // (makeProgramItem "validator" problem.validator)
            // (lib.mergeAttrsList (
              lib.mapAttrsToList (
                n: g: makeProgramItem (if flattened then "generator_${n}" else "generator/${n}") g
              ) problem.generators
            ))
            // (lib.mergeAttrsList (
              lib.mapAttrsToList (
                n: s:
                lib.optionalAttrs s.participantVisibility (
                  if flattened then { "solution_${n}" = s.src; } else { "solution/${n}" = s.src; }
                )
              ) problem.solutions
            ));
        in
        lib.concatMapAttrsStringSep "\n" (
          destPath: src:
          let
            destParentDir = builtins.dirOf destPath;
          in
          ''
            mkdir -p ${dest}/${destParentDir}
            cp -r ${src} ${dest}/${destPath}
          ''
        ) visiblePrograms;

      # Shell command to copy samples.
      samplesCommand =
        {
          problem,
          dest,
          outputsAsDirectory ? false,
          outputName,
          naming ?
            { testCaseName, index }:
            {
              input = "${testCaseName}.in";
              output = "${testCaseName}.ans";
            },
        }:
        lib.concatStringsSep "\n" (
          lib.imap0 (
            index: tc:
            let
              names = naming {
                inherit index;
                testCaseName = tc.name;
              };
            in
            ''
              mkdir -p ${dest}/${builtins.dirOf names.input}
              mkdir -p ${dest}/${builtins.dirOf names.output}
              cp ${tc.data.input} ${dest}/${names.input}
              ${
                if outputsAsDirectory then
                  "cp -r ${tc.data.outputs} ${dest}/${builtins.dirOf names.output}"
                else
                  let
                    outputPath = "${dest}/${names.output}";
                  in
                  if outputName == null then
                    "touch ${outputPath}"
                  else
                    "cp ${tc.data.outputs}/${lib.escapeShellArg outputName} ${outputPath}"
              }
            ''
          ) problem.samples
        );

      # Compile the source code (usually C++) to a native executable file or shared library file.
      # For platforms that require the checker etc. to be a binary executable file.
      compileNative =
        {
          problemName,
          programName,
          src,
          stdenv, # pkgsStatic.stdenv is recommended
          compileCommand, # Should compile `program.code` to `program`
          installDest ? "bin/program",
        }:
        stdenv.mkDerivation {
          name = "hull-nativeCompiled-${problemName}-${programName}";
          unpackPhase = ''
            cp ${src} program.code
          '';
          buildPhase = ''
            runHook preBuild
            ${compileCommand}
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            install -Dm755 program $out/${installDest}
            runHook postInstall
          '';
        };
    };
}
