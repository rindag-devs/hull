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
  pkgs,
  cplib,
  cplibInitializers,
}:

{
  # Problem type.
  # Currently supports "batch" and "stdioInteraction"
  type ? "batch",

  # The short name for the problem used within DOMjudge. Defaults to the problem's `name`.
  problemId ? null,

  # Whether to package the output as a zip file. DOMjudge requires this.
  zipped ? true,

  # Conversion rate from Hull's ticks to milliseconds.
  # 1ms = 1e7 ticks is a common value for wasmtime.
  ticksPerMs ? 1.0e7,

  # The name of the document from `problem.documents` to be used as the problem statement.
  # e.g., "statement.en.pdf"
  statement ? null,

  # Whether to patch CPLib programs to use Kattis-compatible initializers, which work with DOMjudge.
  patchCplibProgram ? true,

  # Extension name of the main correct solution source file.
  stdExtName ? "cpp",

  # Extension name of the checker or interactor.
  checkerExtName ? "cpp",

  # The name of the test case output that will be used as the output of the DOMjudge test case.
  outputName ? if type == "stdioInteraction" then null else "output",

  # A map of name to file path. These files will be placed in `attachments/`.
  attachments ? { },

  # Compile command for the native static checker or interactor.
  checkerCompileCommand ? "$CXX -x c++ program.code -o program -lm -fno-stack-limit -std=c++23 -O3 -static",

  # Specify the target system for the package.
  # `null` means using the local system.
  # e.g.: "aarch64-multiplatform" for ARM64 Linux.
  targetSystem ? null,
}:

{
  _type = "hullProblemTarget";
  __functor =
    self:
    {
      displayName,
      testCases,
      checker,
      judger,
      documents,
      solutions,
      tickLimit,
      memoryLimit,
      mainCorrectSolution,
      generators,
      ...
    }@problem:
    let
      problemDisplayName = displayName.en or problem.name;

      # Use the provided problemId or default to the problem's name.
      finalProblemId = if problemId != null then problemId else problem.name;

      # Compile native, statically-linked executables for checker/manager.
      # DOMjudge requires native binaries, not WASM, for these components.
      compileNative =
        {
          programSrc,
          compileCommand,
          mode, # "checker" or "interactor"
        }:
        let
          patchedSrc =
            if !patchCplibProgram then
              programSrc
            else
              hull.patchCplibProgram (
                {
                  problemName = problem.name;
                  src = programSrc;
                }
                // (
                  if mode == "checker" then
                    {
                      checker = "::cplib_initializers::kattis::checker::Initializer()";
                      extraIncludes = [ "\"kattis_checker.hpp\"" ];
                    }
                  else if mode == "interactor" then
                    {
                      interactor = "::cplib_initializers::kattis::interactor::Initializer()";
                      extraIncludes = [ "\"kattis_interactor.hpp\"" ];
                    }
                  else
                    throw "Invalid mode `${mode}`"
                )
              );
          pkgsTarget = if targetSystem == null then pkgs else pkgs.pkgsCross.${targetSystem};
        in
        pkgsTarget.pkgsStatic.stdenv.mkDerivation {
          name = "hull-kattisNativeChecker-${problem.name}";
          unpackPhase = ''
            cp ${patchedSrc} program.code
            cp ${cplib}/cplib.hpp cplib.hpp
            ${
              if mode == "checker" then
                "cp ${cplibInitializers}/include/kattis/checker.hpp kattis_checker.hpp"
              else if mode == "interactor" then
                "cp ${cplibInitializers}/include/kattis/interactor.hpp kattis_interactor.hpp"
              else
                throw "Invalid mode `${mode}`"
            }
          '';
          buildPhase = ''
            runHook preBuild
            ${compileCommand}
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            install -Dm755 program $out/bin/program
            runHook postInstall
          '';
        };

      compiledChecker = compileNative {
        programSrc = checker.src;
        compileCommand = checkerCompileCommand;
        mode = if type == "stdioInteraction" then "interactor" else "checker";
      };

      # Generate content for domjudge-problem.ini
      iniContent = ''
        name='${problemDisplayName}'
        timelimit='${toString (tickLimit / (ticksPerMs * 1000))}'
        externalId='${problem.name}'
        ${lib.optionalString (type == "stdioInteraction") "special_run='run'"}
        ${lib.optionalString (type == "batch") "special_compare='compare'"}
      '';

      # Generate content for problem.yaml
      yamlContent = builtins.toJSON {
        name = problemDisplayName;
        type = "pass-fail" + (lib.optionalString (type == "stdioInteraction") " interactive");
        validation = "custom" + (lib.optionalString (type == "stdioInteraction") " interactive");
        limits = {
          time_limit = problem.tickLimit / (ticksPerMs * 1000.0);
          memory = memoryLimit / (1024 * 1024);
        };
      };

      # Helper to generate shell commands for copying attachments.
      copyAttachmentsCommand =
        let
          makeProgramItem =
            name: program:
            if program.participantVisibility == "src" then
              { "${name}.${hull.language.toFileExtension program.language}" = program.src; }
            else if program.participantVisibility == "wasm" then
              { "${name}.wasm" = program.wasm; }
            else
              { };

          visiblePrograms =
            (makeProgramItem "checker" checker)
            // (lib.mergeAttrsList (lib.mapAttrsToList (n: g: makeProgramItem "generator_${n}" g) generators))
            // (lib.mergeAttrsList (
              lib.mapAttrsToList (
                n: s: lib.optionalAttrs s.participantVisibility { "solution_${n}" = s.src; }
              ) solutions
            ));
          allAttachments = attachments // visiblePrograms;
        in
        lib.concatMapAttrsStringSep "\n" (
          dest: src: "cp ${src} $tmpdir/attachments/${dest}"
        ) allAttachments;

    in
    pkgs.runCommandLocal
      ("hull-problemTargetOutput-${problem.name}-domjudge" + (lib.optionalString zipped ".zip"))
      { nativeBuildInputs = [ pkgs.zip ]; }
      ''
        tmpdir=$(mktemp -d)

        # Create metadata files
        echo ${lib.escapeShellArg iniContent} > $tmpdir/domjudge-problem.ini
        echo ${lib.escapeShellArg yamlContent} > $tmpdir/problem.yaml

        # Copy test data
        mkdir -p $tmpdir/data/sample $tmpdir/data/secret
        sample_idx=1
        secret_idx=1
        ${lib.concatMapStringsSep "\n" (
          tc:
          let
            isSample = (builtins.elem "sample" tc.groups) || (builtins.elem "sample_large" tc.groups);
            dir = if isSample then "sample" else "secret";
            idxVar = "${dir}_idx";
          in
          ''
            cp ${tc.data.input} $tmpdir/data/${dir}/''${${idxVar}}.in
            ${
              if outputName != null then "cp ${tc.data.outputs}/${outputName}" else "touch"
            } $tmpdir/data/${dir}/''${${idxVar}}.ans
            ${idxVar}=$((''${${idxVar}} + 1))
          ''
        ) (builtins.attrValues testCases)}

        # Copy checker or interactor
        install ${compiledChecker}/bin/program -Dm755 $tmpdir/output_validators/checker/run

        # Copy problem statement
        ${lib.optionalString (statement != null) ''
          mkdir -p $tmpdir/problem_statement
          cp ${documents.${statement}.path} "$tmpdir/problem_statement/problem.pdf"
        ''}

        # Copy solutions
        mkdir -p $tmpdir/submissions/accepted
        cp ${mainCorrectSolution.src} $tmpdir/submissions/accepted/std.${stdExtName}

        # Copy attachments
        mkdir -p $tmpdir/attachments
        ${copyAttachmentsCommand}

        # Zip the final package
        ${
          if zipped then
            ''
              (cd $tmpdir && zip -r ../${finalProblemId}.zip .)
              mv $tmpdir/../${finalProblemId}.zip $out
            ''
          else
            ''
              mkdir $out
              mv $tmpdir/* $out/
            ''
        }
      '';
}
