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
  # batch -> traditional (with or without grader)
  # stdioInteraction -> stdio interaction
  # answerOnly -> submit answer
  type ? "batch",

  # Whether to enable Codeforces Polygon style two step interaction.
  # Used when type == "stdioInteraction"
  twoStepInteraction ? false,

  # Score scaling factor. Hull uses a 0.0-1.0 scale, while UOJ uses integers.
  scoreScale ? 100.0,

  # Whether to package the output as a zip file.
  zipped ? true,

  # Conversion rate from Hull's ticks to UOJ's milliseconds.
  ticksPerMs ? 1.0e7,

  # Grader source codes for function-style interaction problems.
  # Attr set of { c, cpp, pas } to file paths.
  graderSrcs ? null,

  # The name of the test case output that will be used as the output of the UOJ test case.
  outputName ? if type == "stdioInteraction" then null else "output",

  # A map of name to file path. These files will be placed in `require/`.
  extraRequireFiles ? { },

  # A map of name to file path. These files will be placed in `download/`.
  extraDownloadFiles ? { },

  # Whether to patch CPLib programs, i.e. replace the default initializer.
  patchCplibProgram ? true,

  # File suffix (ext name with point) for compiled programs (checker, interactor, etc.).
  # UOJ determines the language by file extension.
  programSuffix ? "20.cpp",

  # Enable integer mode for score. Usually applies to UOJ community edition.
  integerScore ? false,

  # Enable integer mode for time limit. Usually applies to UOJ community edition.
  integerTimeLimit ? false,
}:

{
  _type = "hullProblemTarget";
  __functor =
    self:
    {
      testCases,
      subtasks,
      solutions,
      checker,
      validator,
      documents,
      generators,
      ...
    }@problem:
    let
      # Transform Hull subtasks to UOJ subtasks.
      # UOJ's 'min' mode is the only one used. Hull's 'sum' mode is simulated by
      # creating a separate UOJ subtask for each test case.
      uojSubtasks =
        let
          subtasksWithIndex = lib.imap0 (index: st: { inherit index st; }) subtasks;
        in
        lib.concatMap (
          { index, st }:
          if st.scoringMethod == "sum" then
            let
              numTestCases = builtins.length st.testCases;
              scorePerCase = if numTestCases > 0 then st.fullScore / numTestCases else 0;
              scaledScore = scorePerCase * scoreScale;
            in
            map (tc: {
              score = if integerScore then builtins.floor scaledScore else scaledScore;
              testCases = [ tc ];
            }) st.testCases
          else
            [
              {
                score =
                  let
                    scaledScore = st.fullScore * scoreScale;
                  in
                  if integerScore then builtins.floor scaledScore else scaledScore;
                testCases = st.testCases;
              }
            ]
        ) subtasksWithIndex;

      # Create a flat list of UOJ test points.
      # This renumbers and duplicates Hull test cases to fit UOJ's linear structure.
      uojTestPoints =
        let
          indexedSubtasks = lib.imap0 (i: st: st // { uojSubtaskIndex = i; }) uojSubtasks;
          points = lib.concatMap (
            st:
            map (tc: {
              inherit (st) uojSubtaskIndex;
              hullTestCase = tc;
            }) st.testCases
          ) indexedSubtasks;
        in
        lib.imap0 (i: p: p // { uojPointIndex = i + 1; }) points;

      # Generate the content for problem.conf
      problemConfContent =
        let
          sampleTestCases = lib.filterAttrs (
            _: { groups, ... }: (builtins.elem "sample" groups) || (builtins.elem "sample_large" groups)
          ) testCases;
          nSampleTests = builtins.length (builtins.attrValues sampleTestCases);

          subtaskEnds = builtins.foldl' (
            accList: st:
            accList ++ [ ((if accList == [ ] then 0 else lib.last accList) + (builtins.length st.testCases)) ]
          ) [ ] uojSubtasks;

          subtaskEndLines = lib.concatStringsSep "\n" (
            lib.imap1 (i: end: "subtask_end_${toString i} ${toString end}") subtaskEnds
          );
          subtaskScoreLines = lib.concatStringsSep "\n" (
            lib.imap1 (i: st: "subtask_score_${toString i} ${toString st.score}") uojSubtasks
          );

          subtaskTypeLines = lib.concatStringsSep "\n" (
            map (i: "subtask_type_${toString i} min") (lib.range 1 (builtins.length uojSubtasks))
          );
        in
        ''
          use_builtin_judger on
          ${lib.optionalString (!integerScore) "score_type real-6"}
          ${lib.optionalString (graderSrcs != null) "with_implementer on"}
          ${lib.optionalString (type == "stdioInteraction") "interaction_mode on"}
          ${lib.optionalString (type == "answerOnly") "submit_answer on"}
          n_tests ${toString (builtins.length uojTestPoints)}
          n_ex_tests ${toString nSampleTests}
          n_sample_tests ${toString nSampleTests}
          n_subtasks ${toString (builtins.length uojSubtasks)}
          input_pre ${problem.name}
          input_suf in
          output_pre ${problem.name}
          output_suf out
          time_limit ${
            let
              timeSec = problem.tickLimit / ticksPerMs / 1000;
            in
            toString (if integerTimeLimit then builtins.floor timeSec else timeSec)
          }
          memory_limit ${toString (builtins.floor (problem.memoryLimit / (1024 * 1024)))}
          ${subtaskEndLines}
          ${subtaskScoreLines}
          ${subtaskTypeLines}
        '';

      finalChecker =
        if !patchCplibProgram then
          checker.src
        else if type == "stdioInteraction" then
          hull.patchCplibProgram {
            problemName = problem.name;
            src = "${cplibInitializers}/include/testlib/checker_two_step.cpp";
            includeReplacements = [
              [
                "^testlib/checker.hpp$"
                "testlib_checker.hpp"
              ]
              [
                "^"
                "require/"
              ]
            ];
          }
        else
          hull.patchCplibProgram {
            problemName = problem.name;
            src = checker.src;
            checker = "::cplib_initializers::testlib::checker::Initializer(false)";
            extraIncludes = [ "\"require/testlib_checker.hpp\"" ];
            includeReplacements = [
              [
                "^"
                "require/"
              ]
            ];
          };

      interactor =
        if twoStepInteraction then
          hull.patchCplibProgram {
            problemName = problem.name;
            src = checker.src;
            interactor = "::cplib_initializers::testlib::interactor_two_step::Initializer()";
            extraIncludes = [ "\"require/testlib_interactor_two_step.hpp\"" ];
            includeReplacements = [
              [
                "^"
                "require/"
              ]
            ];
          }
        else
          hull.patchCplibProgram {
            problemName = problem.name;
            src = checker.src;
            interactor = "::cplib_initializers::testlib::interactor::Initializer(false)";
            extraIncludes = [ "\"require/testlib_interactor.hpp\"" ];
            includeReplacements = [
              [
                "^"
                "require/"
              ]
            ];
          };

      patchedValidator =
        if !patchCplibProgram then
          validator.src
        else
          hull.patchCplibProgram {
            problemName = problem.name;
            src = validator.src;
            validator = "::cplib_initializers::testlib::validator::Initializer()";
            extraIncludes = [ "\"require/testlib_validator.hpp\"" ];
            includeReplacements = [
              [
                "^"
                "require/"
              ]
            ];
          };

      # Helper function to create shell commands for copying files with subdirectories.
      mkCopyCommands =
        destDir: files:
        lib.concatMapAttrsStringSep "\n" (
          destPath: srcPath:
          let
            destParentDir = builtins.dirOf destPath;
          in
          ''
            mkdir -p ${destDir}/${lib.escapeShellArg destParentDir}
            cp -f ${srcPath} ${destDir}/${lib.escapeShellArg destPath}
          ''
        ) files;

    in
    pkgs.runCommandLocal
      ("hull-problemTargetOutput-${problem.name}-uoj" + (lib.optionalString zipped ".zip"))
      {
        nativeBuildInputs = [ pkgs.zip ];
      }
      ''
        tmpdir=$(mktemp -d)

        # Create directory structure
        mkdir -p $tmpdir/download/document
        mkdir -p $tmpdir/download/solution
        mkdir -p $tmpdir/download/generator
        mkdir -p $tmpdir/require

        # Write problem.conf
        echo ${lib.escapeShellArg problemConfContent} > $tmpdir/problem.conf

        # Copy test data, renumbering as needed
        ${lib.concatMapStringsSep "\n" (p: ''
          cp ${p.hullTestCase.data.input} $tmpdir/${problem.name}${toString p.uojPointIndex}.in
          ${
            let
              outputPath = "$tmpdir/${problem.name}${toString p.uojPointIndex}.out";
            in
            if outputName == null then
              "touch ${outputPath}"
            else
              "cp ${p.hullTestCase.data.outputs}/${lib.escapeShellArg outputName} ${outputPath}"
          }
        '') uojTestPoints}

        # Copy sample data
        ${lib.concatStringsSep "\n" (
          lib.imap1
            (i: tc: ''
              cp ${tc.data.input} $tmpdir/ex_${problem.name}${toString i}.in
              ${
                let
                  outputPath = "$tmpdir/ex_${problem.name}${toString i}.out";
                in
                if outputName == null then
                  "touch ${outputPath}"
                else
                  "cp ${tc.data.outputs}/${lib.escapeShellArg outputName} ${outputPath}"
              }
            '')
            (
              lib.attrValues (
                lib.filterAttrs (
                  _: { groups, ... }: (builtins.elem "sample" groups) || (builtins.elem "sample_large" groups)
                ) testCases
              )
            )
        )}

        # Copy judger programs (checker, validator, interactor, graders)
        cp ${patchedValidator} $tmpdir/val${programSuffix}
        ${lib.optionalString (
          type != "stdioInteraction" || twoStepInteraction
        ) "cp ${finalChecker} $tmpdir/chk${programSuffix}"}
        ${lib.optionalString (
          type == "stdioInteraction"
        ) "cp ${interactor} $tmpdir/interactor${programSuffix}"}
        ${lib.optionalString (graderSrcs != null) (
          lib.concatMapAttrsStringSep "\n" (
            lang: src: "cp ${src} $tmpdir/require/implementer.${lang}"
          ) graderSrcs
        )}

        # Copy downloadable files
        ${mkCopyCommands "$tmpdir/download" extraDownloadFiles}

        # Copy require files
        cp ${cplib}/cplib.hpp $tmpdir/require/cplib.hpp
        cp ${cplibInitializers}/include/testlib/checker.hpp $tmpdir/require/testlib_checker.hpp
        ${lib.optionalString (type == "stdioInteraction") (
          let
            fileName = if twoStepInteraction then "interactor_two_step.hpp" else "interactor.hpp";
          in
          "cp ${cplibInitializers}/include/testlib/${fileName} $tmpdir/require/testlib_${fileName}"
        )}
        cp ${cplibInitializers}/include/testlib/validator.hpp $tmpdir/require/testlib_validator.hpp
        ${mkCopyCommands "$tmpdir/require" extraRequireFiles}

        # Copy visible documents
        ${lib.concatMapAttrsStringSep "\n" (
          docName: doc:
          lib.optionalString doc.participantVisibility "cp ${doc.path} $tmpdir/download/document/${docName}"
        ) documents}

        # Copy visible programs
        ${lib.optionalString (checker.participantVisibility != "no")
          "cp ${checker.${checker.participantVisibility}} $tmpdir/download/checker.${
            if checker.participantVisibility == "src" then
              hull.language.toFileExtension checker.language
            else
              "wasm"
          }"
        }
        ${lib.optionalString (validator.participantVisibility != "no")
          "cp ${validator.${validator.participantVisibility}} $tmpdir/download/validator.${
            if validator.participantVisibility == "src" then
              hull.language.toFileExtension validator.language
            else
              "wasm"
          }"
        }
        ${lib.concatMapAttrsStringSep "\n" (
          genName: gen:
          lib.optionalString (gen.participantVisibility != "no")
            "cp ${gen.${gen.participantVisibility}} $tmpdir/download/generator/${genName}.${
              if gen.participantVisibility == "src" then hull.language.toFileExtension gen.language else "wasm"
            }"
        ) generators}
        ${lib.concatMapAttrsStringSep "\n" (
          solName: sol:
          lib.optionalString sol.participantVisibility "cp ${sol.src} $tmpdir/download/solution/${solName}"
        ) solutions}

        # Zip the result
        ${
          if zipped then
            "(cd $tmpdir && zip -r ../output.zip .) && mv $tmpdir/../output.zip $out"
          else
            "mkdir $out && mv $tmpdir/* $out/"
        }
      '';
}
