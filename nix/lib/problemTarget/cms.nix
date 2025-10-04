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
  # Hull -> CMS
  # batch -> Batch (with or without grader)
  # stdioInteraction -> Communication
  # answerOnly -> OutputOnly
  type ? "batch",

  # Score scaling factor. Hull uses a 0.0-1.0 scale, while CMS uses integers (typically 0-100).
  scoreScale ? 100.0,

  # Conversion rate from Hull's ticks to CMS's milliseconds.
  ticksPerMs ? 1.0e7,

  # A map from language FULL NAME to the document name for problem statements.
  # See https://github.com/cms-dev/cms/blob/v1.5.1/cmscontrib/loaders/base_loader.py#L22
  # Example: { english = "statement.en.pdf"; chinese = "statement.zh.pdf"; }
  statements ? { },

  # The primary language for the statement and problem title, used in task.yaml.
  displayLanguage ? "en",

  # Grader source codes for Batch (grader) problems.
  # Attr set of { c, cpp, pas } to file paths.
  graderSrcs ? { },

  # A map of name to file path. These files will be placed in `sol/`.
  extraSolFiles ? { },

  # The name of the test case output that will be used as the output of the CMS test case.
  outputName ? if type == "stdioInteraction" then null else "output",

  # Compile command for the native static checker or interactor.
  checkerCompileCommand ? "$CXX -x c++ program.code -o program -lm -fno-stack-limit -std=c++23 -O3 -static",

  # Whether to patch CPLib programs to use testlib-compatible initializers.
  patchCplibProgram ? true,

  # A map of name to file path. These files will be placed in `att/`.
  attachments ? { },

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
      subtasks,
      checker,
      documents,
      generators,
      solutions,
      ...
    }@problem:
    let
      sampleTestCases = builtins.filter (
        { groups, ... }: (builtins.elem "sample" groups) || (builtins.elem "sample_large" groups)
      ) (builtins.attrValues testCases);

      # Flatten Hull subtasks into a list of CMS-compatible subtasks.
      # This resolves issues with "sum" scoring and test cases belonging to multiple subtasks.
      # - "sum" scoring subtasks are expanded: one CMS subtask per test case.
      # - "min" scoring subtasks are mapped directly: one CMS subtask per Hull subtask.
      # After generation, the total score is adjusted to be exactly 100.
      cmsSubtasks =
        let
          # Phase 1: Generate the initial list of subtasks based on the original logic.
          initialCmsSubtasks =
            let
              subtasksWithIndex = lib.imap0 (index: st: { inherit index st; }) subtasks;
              normalSubtasks = lib.concatMap (
                { index, st }:
                if st.scoringMethod == "sum" then
                  # For "sum" mode, each test case becomes a separate CMS subtask.
                  let
                    numTestCases = builtins.length st.testCases;
                    scorePerCase = if numTestCases > 0 then st.fullScore / numTestCases else 0;
                  in
                  map (tc: {
                    score = builtins.floor (scorePerCase * scoreScale);
                    testCases = [ tc ]; # Each subtask contains only one test case.
                  }) st.testCases
                else
                  # For "min" mode, the entire Hull subtask maps to one CMS subtask.
                  [
                    {
                      score = builtins.floor (st.fullScore * scoreScale);
                      testCases = st.testCases;
                    }
                  ]
              ) subtasksWithIndex;
              sampleSubtasks =
                if sampleTestCases == [ ] then
                  [ ]
                else
                  [
                    {
                      score = 0;
                      testCases = sampleTestCases;
                    }
                  ];
            in
            sampleSubtasks ++ normalSubtasks;

          # Phase 2: Calculate the total score of the generated subtasks.
          totalScore = builtins.foldl' (acc: st: acc + st.score) 0 initialCmsSubtasks;

        in
        # Phase 3: Validate and adjust the scores to sum to 100.
        if totalScore > 100 then
          throw "The total score of all subtasks (${toString totalScore}) exceeds 100."
        else if totalScore < 100 then
          # If the total score is less than 100, add the remainder to the last subtask.
          # This handles the case where there are no subtasks to adjust.
          if initialCmsSubtasks == [ ] then
            initialCmsSubtasks
          else
            let
              remainder = 100 - totalScore;
              allButLast = lib.lists.init initialCmsSubtasks;
              lastSubtask = lib.lists.last initialCmsSubtasks;
              # Create the updated last subtask with the adjusted score.
              updatedLastSubtask = lastSubtask // {
                score = lastSubtask.score + remainder;
              };
            in
            allButLast ++ [ updatedLastSubtask ]
        # totalScore is exactly 100
        else
          initialCmsSubtasks;

      # Create a flat list of CMS test cases.
      # This renumbers and duplicates Hull test cases to fit CMS's linear structure.
      cmsTestCases =
        let
          points = lib.concatMap (st: map (tc: { hullTestCase = tc; }) st.testCases) cmsSubtasks;
        in
        lib.imap0 (i: p: p // { cmsIndex = i; }) points;

      # Compile native, statically-linked executables for checker/manager.
      # CMS requires native binaries, not WASM, for these components.
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
                      checker = "::cplib_initializers::cms::checker::Initializer()";
                      extraIncludes = [ "\"cms_checker.hpp\"" ];
                    }
                  else if mode == "interactor" then
                    {
                      interactor = "::cplib_initializers::cms::interactor::Initializer()";
                      extraIncludes = [ "\"cms_interactor.hpp\"" ];
                    }
                  else
                    throw "Invalid mode `${mode}`"
                )
              );
          pkgsTarget = if targetSystem == null then pkgs else pkgs.pkgsCross.${targetSystem};
        in
        pkgsTarget.pkgsStatic.stdenv.mkDerivation {
          name = "hull-cmsNativeChecker-${problem.name}";
          unpackPhase = ''
            cp ${patchedSrc} program.code
            cp ${cplib}/cplib.hpp cplib.hpp
            ${
              if mode == "checker" then
                "cp ${cplibInitializers}/include/cms/checker.hpp cms_checker.hpp"
              else if mode == "interactor" then
                "cp ${cplibInitializers}/include/cms/interactor.hpp cms_interactor.hpp"
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

      # Generate content for task.yaml.
      taskYamlContent = {
        name = problem.name;
        title = displayName.${displayLanguage} or problem.name;
        time_limit = problem.tickLimit / (ticksPerMs * 1000.0); # in seconds
        memory_limit = builtins.floor (problem.memoryLimit / (1024 * 1024)); # in MiB
        score_mode = "max_subtask";
        token_mode = "infinite";
        score_precision = 6;
        primary_language = displayLanguage;
        public_testcases = lib.concatMapStringsSep "," toString (
          lib.range 0 ((builtins.length sampleTestCases) - 1)
        );
      }
      // lib.optionalAttrs (type == "batch") {
        infile = "";
        outfile = "";
      }
      // lib.optionalAttrs (type == "answerOnly") { output_only = true; };

      # Generate content for the gen/GEN file, which defines subtasks and test cases.
      genFileContent = lib.concatStringsSep "\n" (
        lib.map (
          st: lib.concatStringsSep "\n" ([ "# ST: ${toString st.score}" ] ++ (map (tc: tc.name) st.testCases))
        ) cmsSubtasks
      );

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
        lib.concatMapAttrsStringSep "\n" (dest: src: "cp ${src} $out/att/${dest}") allAttachments;
    in
    pkgs.runCommandLocal "hull-problemTargetOutput-${problem.name}-cms" { } ''
      # Create directory structure
      mkdir -p $out/input $out/output $out/statement $out/gen $out/check $out/sol $out/att

      # Write task.yaml
      echo ${lib.escapeShellArg (builtins.toJSON taskYamlContent)} > $out/task.yaml

      # Write gen/GEN for subtasks
      echo ${lib.escapeShellArg genFileContent} > $out/gen/GEN

      # Copy test data
      ${lib.concatMapStringsSep "\n" (tc: ''
        cp ${tc.hullTestCase.data.input} $out/input/input${toString tc.cmsIndex}.txt
        ${
          let
            outputPath = "$out/output/output${toString tc.cmsIndex}.txt";
          in
          if outputName == null then
            "touch ${outputPath}"
          else
            "cp ${tc.hullTestCase.data.outputs}/output ${outputPath}"
        }
      '') cmsTestCases}

      # Copy statement
      ${lib.concatMapAttrsStringSep "\n" (
        lang: statement: "cp ${documents.${statement}.path} $out/statement/${lang}.pdf"
      ) statements}

      # Copy checker, manager, graders, and attachments
      cp ${compiledChecker}/bin/program $out/check/${
        if type == "stdioInteraction" then "manager" else "checker"
      }
      ${lib.concatMapAttrsStringSep "\n" (
        lang: src: "cp ${src} $out/sol/${if type == "stdioInteraction" then "stub" else "grader"}.${lang}"
      ) graderSrcs}
      ${lib.concatMapAttrsStringSep "\n" (name: src: "cp ${src} $out/sol/${name}") extraSolFiles}

      # Copy sample data
      ${lib.concatStringsSep "\n" (
        lib.imap0 (i: tc: ''
          cp ${tc.data.input} $out/att/input${toString i}.txt
          ${
            let
              outputPath = "$out/att/output${toString i}.txt";
            in
            if outputName == null then
              "touch ${outputPath}"
            else
              "cp ${tc.data.outputs}/${lib.escapeShellArg outputName} ${outputPath}"
          }
        '') sampleTestCases
      )}

      ${copyAttachmentsCommand}
    '';
}
