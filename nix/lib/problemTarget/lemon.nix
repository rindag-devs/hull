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
  # The problem type.
  # Since Hull's judger is customizable, you need to manually map it.
  #
  # Hull -> Lemon
  # batch -> 0 (traditional, if grader == null) or 2 (grader interaction, if grader != null)
  # answerOnly -> 1
  type ? "batch",

  # Score scaling factor. Hull uses a 0.0-1.0 scale, while Lemon uses integers.
  scoreScale ? 100.0,

  # Conversion rate from Hull's ticks to Lemon's milliseconds.
  # 1ms = 1e7 ticks is a common value for wasmtime.
  ticksPerMs ? 1.0e7,

  # Whether to patch CPLib programs to use Lemon-specific initializers.
  patchCplibProgram ? true,

  # Source of grader.
  graderSrc ? null,

  # Source of interaction lib header (.h) file.
  interactionLib ? null,

  # The name of interaction lib header (.h) file. e.g. `lib.h`
  interactionLibName ? null,

  # The name of the test case output that will be used as the output of the UOJ test case.
  outputName ? if type == "stdioInteraction" then null else "output",

  # Compile command for checker, which should build a statically linked executable.
  checkerCompileCommand ? "$CXX -x c++ checker.code -o checker -lm -fno-stack-limit -std=c++23 -O3 -static",

  # A map of solution and extension name.
  # Example { std = "cpp"; bf = "c"; }
  solutionExtNames ? { },

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
      name,
      displayName,
      testCases,
      subtasks,
      solutions,
      checker,
      judger,
      languages,
      ...
    }:
    let
      taskTypeEnum = {
        batch = 0;
        answerOnly = 1;
        graderInteraction = 2;
      };

      # Map Hull's judger type to Lemon's TaskType enum.
      # Traditional=0, AnswersOnly=1, Interaction=2
      taskType =
        if type == "batch" then
          if graderSrc != null then taskTypeEnum.graderInteraction else taskTypeEnum.batch
        else if type == "answerOnly" then
          taskTypeEnum.batch
        else
          throw "Invalid problem type ${type}";

      # Lemon's "TestCase" is equivalent to a Hull "Subtask".
      # For Hull subtasks with 'sum' scoring, we create a separate Lemon TestCase for each Hull test case.
      lemonTestCases =
        let
          subtasksWithIndex = lib.imap0 (index: st: { inherit index st; }) subtasks;
        in
        lib.concatMap (
          { index, st }:
          if st.scoringMethod == "sum" then
            # For 'sum' scoring, each test case becomes a separate Lemon test case.
            let
              numTestCases = builtins.length st.testCases;
              # Distribute the subtask's score among its test cases.
              scorePerCase = if numTestCases > 0 then st.fullScore / numTestCases else 0;
            in
            map (tc: {
              fullScore = builtins.floor (scorePerCase * scoreScale);
              timeLimit = builtins.floor (tc.tickLimit / ticksPerMs);
              memoryLimit = builtins.floor (tc.memoryLimit / (1024 * 1024));
              inputFiles = [ "${name}/${tc.name}.in" ];
              outputFiles = [ "${name}/${tc.name}.out" ];
            }) st.testCases
          else
            # For 'min' scoring (default), the entire subtask is one Lemon test case.
            let
              # Ensure all test cases in a subtask have the same limits.
              firstTc = builtins.head st.testCases;
              firstTl = firstTc.tickLimit;
              firstMl = firstTc.memoryLimit;
              reduceSame =
                first: list:
                builtins.foldl' (
                  a: b:
                  if a == b then
                    a
                  else
                    throw "In problem ${name}, subtask #${toString index}, test cases have different tick or memory limits. This is not allowed for 'min' scoring subtasks in the Lemon target."
                ) first list;
              reducedTl = reduceSame firstTl (map ({ tickLimit, ... }: tickLimit) st.testCases);
              reducedMl = reduceSame firstMl (map ({ memoryLimit, ... }: memoryLimit) st.testCases);
            in
            [
              # Return a list with one element for concatMap
              {
                fullScore = builtins.floor (st.fullScore * scoreScale);
                timeLimit = builtins.floor (reducedTl / ticksPerMs);
                memoryLimit = builtins.floor (reducedMl / (1024 * 1024));
                inputFiles = map (tc: "${name}/${tc.name}.in") st.testCases;
                outputFiles = map (tc: "${name}/${tc.name}.out") st.testCases;
              }
            ]
        ) subtasksWithIndex;

      # The main JSON content for the .cdf file.
      # Structure is based on reverse-engineering LemonLime's source code.
      lemonJsonContent = {
        version = "1.0";
        contestTitle = name;

        tasks = [
          {
            problemTitle = name;
            sourceFileName = name;
            inputFileName = "${name}.in";
            outputFileName = "${name}.out";
            standardInputCheck = true;
            standardOutputCheck = true;
            subFolderCheck = true;
            comparisonMode = 4;
            specialJudge = "${name}/checker";

            inherit taskType;

            # For grader interaction problems.
            grader = if taskType == taskTypeEnum.graderInteraction then "${name}/grader.cpp" else ""; # Assuming single grader file
            interactor = if interactionLibName != null then "${name}/${interactionLibName}" else null;
            interactorName = if interactionLibName != null then interactionLibName else null;

            # Default compiler configurations.
            compilerConfiguration = {
              "g++" = "C++20 O3";
              "gcc" = "C17 O3";
            };

            # Map Hull test cases to Lemon test cases.
            testCases = lemonTestCases;
          }
        ];

        # Map Hull solutions to Lemon contestants.
        contestants = lib.mapAttrsToList (solName: _: {
          contestantName = solName;
          checkJudged = [ false ];
          compileState = [ 1 ]; # NoValidSourceFile
          sourceFile = [ "" ];
          compileMesaage = [ "" ];
          inputFiles = [ [ ] ];
          result = [ [ ] ];
          message = [ [ ] ];
          score = [ [ ] ];
          timeUsed = [ [ ] ];
          memoryUsed = [ [ ] ];
          judgingTime_date = 0;
          judgingTime_time = 0;
          judgingTime_timespec = 0;
        }) solutionExtNames;
      };

      # Patch the checker source to use the Lemon initializer from cplib-initializers.
      patchedChecker =
        if !patchCplibProgram then
          checker.src
        else
          hull.patchCplibProgram {
            problemName = name;
            src = checker.src;
            checker = "::cplib_initializers::lemon::checker::Initializer()";
            extraIncludes = [ "\"lemon_checker.hpp\"" ];
          };

      pkgsTarget = if targetSystem == null then pkgs else pkgs.pkgsCross.${targetSystem};

      # Compiled, static-linked checker executable
      compiledChecker = pkgsTarget.pkgsStatic.stdenv.mkDerivation {
        name = "hull-lemonCompiledChecker-${name}";
        unpackPhase = ''
          cp ${patchedChecker} checker.code
          cp ${cplib}/cplib.hpp cplib.hpp
          cp ${cplibInitializers}/include/lemon/checker.hpp lemon_checker.hpp
        '';
        buildPhase = ''
          runHook preBuild
          ${checkerCompileCommand}
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          install -Dm755 checker $out/bin/checker
          runHook postInstall
        '';
      };

    in
    pkgs.runCommandLocal "hull-problemTargetOutput-${name}-lemon" { } ''
      # Create directory structure
      mkdir -p $out/data/${name} $out/source

      # Write the main contest file
      echo '${builtins.toJSON lemonJsonContent}' > $out/${name}.cdf

      # Copy test data (inputs and outputs)
      ${lib.concatMapAttrsStringSep "\n" (tcName: tc: ''
        cp ${tc.data.input} $out/data/${name}/${tcName}.in
        ${
          let
            outputPath = "$out/data/${name}/${tcName}.out";
          in
          if outputName == null then
            "touch ${outputPath}"
          else
            "cp ${tc.data.outputs}/${lib.escapeShellArg outputName} ${outputPath}"
        }
      '') testCases}

      # Copy checker executable
      # Lemon expects a native executable, not WASM.
      cp ${compiledChecker}/bin/checker $out/data/${name}/checker

      # Copy grader source and interaction lib for interaction problems
      ${lib.optionalString (taskType == taskTypeEnum.graderInteraction) (''
        cp ${graderSrc} $out/data/${name}/grader.cpp
        ${lib.optionalString (
          interactionLibName != null
        ) "cp ${interactionLib} $out/data/${name}/${interactionLibName}"}
      '')}

      # Copy solution sources into contestant folders
      ${lib.concatMapAttrsStringSep "\n" (solName: ext: ''
        mkdir -p $out/source/${solName}/${name}
        cp ${solutions.${solName}.src} $out/source/${solName}/${name}/${name}.${ext}
      '') solutionExtNames}
    '';
}
