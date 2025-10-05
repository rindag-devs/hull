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
  # Hull -> Hydro
  # batch -> default
  # stdioInteraction -> interactive
  # answerOnly -> submit_answer
  type ? "batch",

  # Score scaling factor. Hull uses a 0.0-1.0 scale, while Hydro uses 0-100.
  scoreScale ? 100.0,

  # A map from language code to the document name for problem statements.
  # Example: { en = "statement.en.pdf"; zh = "statement.zh.pdf"; }
  statements ? { },

  # The default display language for the problem statement if not specified otherwise.
  defaultDisplayLanguage ? "en",

  # The owner's UID in Hydro for the problem.yaml.
  owner ? 0,

  # A list of tags for the problem.yaml.
  tag ? [ ],

  # Whether to package the output as a zip file.
  zipped ? true,

  # File extension for checker and interactor.
  # Hydro determines the language by file extension.
  checkerExtName ? "cc.cc23o2",

  # File extension for validator.
  # Hydro determines the language by file extension.
  validatorExtName ? "cc.cc23o2",

  # Conversion rate from Hull's ticks to Hydro's milliseconds.
  # 1ms = 1e7 ticks is a common value for wasmtime.
  ticksPerMs ? 1.0e7,

  # A map of name to file path.
  # These files will be placed in `testdata/`.
  testDataExtraFiles ? { },

  # A list of `user_extra_files` for the problem.yaml.
  userExtraFiles ? [ ],

  # A list of `judge_extra_files` for the problem.yaml.
  judgeExtraFiles ? [ ],

  # Whether to patch CPLib programs, i.e. replace the default initializer.
  patchCplibProgram ? true,

  # Grader source code for function-style interaction problems.
  graderSrc ? null,

  # Compile command for grader.
  graderCompileCommand ? "g++ -x c++ grader.code -c -o grader.o -fno-stack-limit -std=c++23 -O3",

  # The name of the test case output that will be used as the output of the Hydro test case.
  outputName ? if type == "stdioInteraction" then null else "output",

  # Content of custom compile.sh.
  compileSh ? null,

  # Content of custom execute.sh.
  executeSh ? null,

  # Allowed programming languages. A list of `langs` for the problem.yaml.
  # Null means all languages are allowed.
  allowedLanguages ? null,

  # Extra attachment files placed in `additional_file/`.
  attachments ? { },
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
      validator,
      tickLimit,
      memoryLimit,
      documents,
      generators,
      solutions,
      ...
    }@problem:
    let
      testDataExtraFiles' = {
        "cplib.hpp" = "${cplib}/cplib.hpp";
        "syzoj_checker.hpp" = "${cplibInitializers}/include/syzoj/checker.hpp";
        "testlib_interactor.hpp" = "${cplibInitializers}/include/testlib/interactor.hpp";
        "testlib_validator.hpp" = "${cplibInitializers}/include/testlib/validator.hpp";
      }
      // (lib.optionalAttrs (graderSrc != null) { "grader.code" = graderSrc; })
      // testDataExtraFiles;

      # Content for problem.yaml
      problemYamlContent = {
        title = displayName.${defaultDisplayLanguage} or problem.name;
        inherit owner tag;
      };

      # Content for testdata/config.yaml
      configYamlContent = {
        type =
          if type == "batch" then
            "default"
          else if type == "stdioInteraction" then
            "interactive"
          else if type == "answerOnly" then
            "submit_answer"
          else
            throw "Invalid problem type ${type}";
        time = "${toString (builtins.floor (tickLimit / ticksPerMs))}ms";
        memory = "${toString (builtins.floor (memoryLimit / (1024 * 1024)))}m";
        subtasks = lib.imap0 (index: st: {
          id = index + 1;
          score = builtins.floor (st.fullScore * scoreScale);
          type = st.scoringMethod;
          cases = map (tc: {
            input = "${tc.name}.in";
            output = if outputName != null then "${tc.name}.ans" else "/dev/null";
          }) st.testCases;
        }) subtasks;
        validator = "validator.${validatorExtName}";
        user_extra_files = lib.unique (
          (lib.optional (finalCompileSh != null) "compile.sh")
          ++ (lib.optional (executeSh != null) "execute.sh")
          ++ (lib.optional (graderSrc != null) "grader.code")
          ++ userExtraFiles
        );
        judge_extra_files = lib.unique (
          [
            "cplib.hpp"
            "syzoj_checker.hpp"
            "testlib_interactor.hpp"
            "testlib_validator.hpp"
          ]
          ++ judgeExtraFiles
        );
      }
      // lib.optionalAttrs (checker != null) (
        if type == "stdioInteraction" then
          {
            interactor = "checker.${checkerExtName}";
          }
        else
          {
            checker = "checker.${checkerExtName}";
            checker_type = "syzoj";
          }
      )
      // lib.optionalAttrs (allowedLanguages != null) { langs = allowedLanguages; };

      # Shell command to copy test case input/output files
      testDataCommand = lib.concatMapStringsSep "\n" (tc: ''
        cp ${tc.data.input} $tmpdir/testdata/${tc.name}.in
        ${lib.optionalString (
          outputName != null
        ) "cp ${tc.data.outputs}/${lib.escapeShellArg outputName} $tmpdir/testdata/${tc.name}.ans"}
      '') (lib.attrValues testCases);

      # Shell command to copy documents
      documentsCommand = lib.concatMapAttrsStringSep "\n" (docName: doc: ''
        cp ${doc.path} $tmpdir/additional_file/document_${docName}
      '') (lib.filterAttrs (_: doc: doc.participantVisibility) documents);

      # Shell command to write statements
      statementsCommand = lib.concatMapAttrsStringSep "\n" (lang: docName: ''
        echo '@[PDF](file://document_${docName})' > $tmpdir/problem_${lang}.md
      '') statements;

      # Shell command to copy extra files
      testDataExtraFilesCommand = lib.concatMapAttrsStringSep "\n" (
        name: path: "cp ${path} $tmpdir/testdata/${name}"
      ) testDataExtraFiles';

      patchedChecker =
        if !patchCplibProgram then
          checker.src
        else if type == "stdioInteraction" then
          hull.patchCplibProgram {
            problemName = problem.name;
            src = checker.src;
            interactor = "::cplib_initializers::testlib::interactor::Initializer(true)";
            extraIncludes = [ "\"testlib_interactor.hpp\"" ];
          }
        else
          hull.patchCplibProgram {
            problemName = problem.name;
            src = checker.src;
            checker = "::cplib_initializers::syzoj::checker::Initializer()";
            extraIncludes = [ "\"syzoj_checker.hpp\"" ];
          };

      patchedValidator =
        if !patchCplibProgram then
          validator.src
        else
          hull.patchCplibProgram {
            problemName = problem.name;
            src = validator.src;
            validator = "::cplib_initializers::testlib::validator::Initializer()";
            extraIncludes = [ "\"testlib_validator.hpp\"" ];
          };

      compileShWithGrader = ''
        #!/bin/sh
        set -e
        ${graderCompileCommand}
        case "$HYDRO_LANG" in
          # C languages (gcc)
          c.c99|c.c99o2)
            g++ -x c foo.c -x none grader.o -o foo -lm -fno-stack-limit -fdiagnostics-color=always -std=c99 -O3
            ;;
          c.c11|c.c11o2)
            g++ -x c foo.c -x none grader.o -o foo -lm -fno-stack-limit -fdiagnostics-color=always -std=c11 -O3
            ;;
          c.c17|c.c17o2)
            g++ -x c foo.c -x none grader.o -o foo -lm -fno-stack-limit -fdiagnostics-color=always -std=c17 -O3
            ;;
          c.c23|c.c23o2)
            g++ -x c foo.c -x none grader.o -o foo -lm -fno-stack-limit -fdiagnostics-color=always -std=c23 -O3
            ;;
          # C++ languages (g++)
          cc.cc98|cc.cc98o2)
            g++ -x c++ foo.cc -x none grader.o -o foo -lm -fno-stack-limit -fdiagnostics-color=always -std=c++98 -O3
            ;;
          cc.cc03|cc.cc03o2)
            g++ -x c++ foo.cc -x none grader.o -o foo -lm -fno-stack-limit -fdiagnostics-color=always -std=c++03 -O3
            ;;
          cc.cc11|cc.cc11o2)
            g++ -x c++ foo.cc -x none grader.o -o foo -lm -fno-stack-limit -fdiagnostics-color=always -std=c++11 -O3
            ;;
          cc.cc14|cc.cc14o2)
            g++ -x c++ foo.cc -x none grader.o -o foo -lm -fno-stack-limit -fdiagnostics-color=always -std=c++14 -O3
            ;;
          cc.cc17|cc.cc17o2)
            g++ -x c++ foo.cc -x none grader.o -o foo -lm -fno-stack-limit -fdiagnostics-color=always -std=c++17 -O3
            ;;
          cc.cc20|cc.cc20o2)
            g++ -x c++ foo.cc -x none grader.o -o foo -lm -fno-stack-limit -fdiagnostics-color=always -std=c++20 -O3
            ;;
          cc.cc2a|cc.cc2ao2)
            g++ -x c++ foo.cc -x none grader.o -o foo -lm -fno-stack-limit -fdiagnostics-color=always -std=c++20 -O3
            ;;
          cc.cc23|cc.cc23o2)
            g++ -x c++ foo.cc -x none grader.o -o foo -lm -fno-stack-limit -fdiagnostics-color=always -std=c++23 -O3
            ;;
          *)
            echo "Unsupported HYDRO_LANG: $HYDRO_LANG" >&2
            exit 1
            ;;
        esac
      '';

      finalCompileSh =
        if compileSh != null then
          compileSh
        else if graderSrc != null then
          compileShWithGrader
        else
          null;
    in
    pkgs.runCommandLocal
      ("hull-problemTargetOutput-${problem.name}-hydro" + (lib.optionalString zipped ".zip"))
      {
        nativeBuildInputs = [ pkgs.zip ];
      }
      ''
        tmpdir=$(mktemp -d)

        # Create directory structure
        mkdir -p $tmpdir/additional_file $tmpdir/testdata

        # Write metadata and config files
        echo ${lib.escapeShellArg (builtins.toJSON problemYamlContent)} > $tmpdir/problem.yaml
        echo ${lib.escapeShellArg (builtins.toJSON configYamlContent)} > $tmpdir/testdata/config.yaml

        # Copy problem documents
        ${documentsCommand}
        ${statementsCommand}

        # Copy test data (inputs and answers)
        ${testDataCommand}

        # Copy checker, interactor, validator
        cp ${patchedChecker} $tmpdir/testdata/checker.${checkerExtName}
        cp ${patchedValidator} $tmpdir/testdata/validator.${validatorExtName}

        # Write compile.sh and execute.sh
        ${lib.optionalString (
          finalCompileSh != null
        ) "echo ${lib.escapeShellArg finalCompileSh} > $tmpdir/testdata/compile.sh"}
        ${lib.optionalString (
          executeSh != null
        ) "echo ${lib.escapeShellArg executeSh} > $tmpdir/testdata/execute.sh"}

        # Copy extra files
        ${testDataExtraFilesCommand}

        # Additional files
        ${hull.problemTarget.utils.samplesCommand {
          inherit problem outputName;
          dest = "$tmpdir/additional_file";
          naming =
            { testCaseName, ... }:
            {
              input = "sample_${testCaseName}.in";
              output = "sample_${testCaseName}.ans";
            };
        }}

        ${hull.problemTarget.utils.participantProgramsCommand {
          inherit problem;
          dest = "$tmpdir/additional_file";
          flattened = true;
        }}

        ${lib.concatMapAttrsStringSep "\n" (
          destPath: src: "cp ${src} $tmpdir/additional_file/${destPath}"
        ) attachments}

        # Zip the result
        ${
          if zipped then
            "(cd $tmpdir && zip -r ../output.zip .) && mv $tmpdir/../output.zip $out"
          else
            "mkdir $out && mv $tmpdir/* $out/"
        }
      '';
}
