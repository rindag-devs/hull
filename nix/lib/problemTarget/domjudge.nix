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
  checkerCompileCommand ?
    includes:
    let
      includeDirCmd = lib.concatMapStringsSep " " (p: "-I${p}") includes;
    in
    "$CXX -x c++ program.code -o program -lm -fno-stack-limit -std=c++23 -O3 -static ${includeDirCmd}",

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
      documents,
      solutions,
      tickLimit,
      memoryLimit,
      mainCorrectSolution,
      generators,
      includes,
      validator,
      ...
    }@problem:
    let
      problemDisplayName = displayName.en or problem.name;

      patchedChecker =
        if !patchCplibProgram then
          checker.src
        else
          hull.patchCplibProgram (
            {
              problemName = problem.name;
              src = checker.src;
            }
            // (
              if type != "stdioInteraction" then
                {
                  checker = "::cplib_initializers::kattis::checker::Initializer()";
                  extraIncludes = [ "\"${cplibInitializers}/include/kattis/checker.hpp\"" ];
                }
              else
                {
                  interactor = "::cplib_initializers::kattis::interactor::Initializer()";
                  extraIncludes = [ "\"${cplibInitializers}/include/kattis/interactor.hpp\"" ];
                }
            )
          );

      compiledChecker = hull.problemTarget.utils.compileNative {
        problemName = problem.name;
        programName = "kattisChecker";
        src = patchedChecker;
        compileCommand = checkerCompileCommand includes;
        stdenv = (if targetSystem == null then pkgs else pkgs.pkgsCross.${targetSystem}).pkgsStatic.stdenv;
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
            isSample = (builtins.elem "sample" tc.groups) || (builtins.elem "sampleLarge" tc.groups);
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
        ${hull.problemTarget.utils.participantProgramsCommand {
          inherit problem;
          dest = "$tmpdir/attachments";
          flattened = true;
        }}

        ${lib.concatMapAttrsStringSep "\n" (destPath: src: "cp ${src} $out/att/${destPath}") attachments}

        # Zip the final package
        ${
          if zipped then
            ''
              (cd $tmpdir && zip -r ../output.zip .)
              mv $tmpdir/../output.zip $out
            ''
          else
            ''
              mkdir $out
              mv $tmpdir/* $out/
            ''
        }
      '';
}
