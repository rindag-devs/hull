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

# Luogu's judging environment enforces `-std=c++14` when compiling custom
# checkers, interactors, and validators. However, Hull's core components,
# which rely on `cplib`, require at least C++ 20. This creates a fundamental
# incompatibility that prevents direct compilation of these programs on Luogu.
#
# To solve this, this target employs a workaround:
# 1. **Pre-compilation:** The C++ 20 program (e.g., checker) is first compiled
#    into a standard `x86_64-linux-gnu` shared library (.so file), since
#    Luogu's environment is fixed and known.
# 2. **Embedding:** The resulting .so file is compressed (using deflate) and
#    then base64-encoded to create a portable string. This reduces the size
#    and makes it embeddable in source code.
# 3. **Wrapping:** This string is embedded into a simple C wrapper program
#    (`sharedWrapper.c`). This wrapper itself is C99 compliant and
#    compiles fine on Luogu with its C++ 14 flags.
# 4. **Runtime Execution:** When Luogu compiles and runs the wrapper, the
#    wrapper decodes the base64 string, inflates the data back into the
#    original .so binary in memory (using `memfd_create`), and then uses
#    `dlopen`/`dlsym` to dynamically load and execute the `main` function
#    from the in-memory shared library.
#
# This allows us to effectively run a C++ 20 compliant program within Luogu's
# C++ 14 constrained environment.
{
  # The problem type.
  # Since Hull's judger is customizable, you need to manually map it.
  #
  # Available options are:
  #
  # - batch, for traditional problems or grader interactive problem
  # - stdioInteraction
  # - answerOnly
  #
  # WARNING: If this is an interactive or answer-only problem, you will need to manually set the
  # corresponding tag on Luogu to judge it normally.
  type ? "batch",

  # Score scaling factor. Hull uses a 0.0-1.0 scale, while Luogu uses integers 0-100.
  scoreScale ? 100.0,

  # Conversion rate from Hull's ticks to Luogu's milliseconds.
  # 1ms = 1e7 ticks is a common value for wasmtime.
  ticksPerMs ? 1.0e7,

  # Whether to patch CPLib programs to use luogu-specific initializers, i.e. Testlib.
  patchCplibProgram ? true,

  # The name of the test case output that will be used as the output of the UOJ test case.
  outputName ? if type == "stdioInteraction" then null else "output",

  # Grader source file, should be in C++.
  graderSrc ? null,

  # This command needs to compile `program.code` into `program.so`, which is a dynamic link library
  # of x86-64-linux-gnu.
  checkerCompileCommand ?
    includes:
    let
      includeDirCmd = lib.concatMapStringsSep " " (p: "-I${p}") includes;
    in
    "$CXX -x c++ program.code -o program.so -std=c++23 -O3 -fPIC -shared ${includeDirCmd}",

  # This command needs to compile `program.code` into `program.so`, which is a dynamic link library
  # of x86-64-linux-gnu.
  validatorCompileCommand ?
    includes:
    let
      includeDirCmd = lib.concatMapStringsSep " " (p: "-I${p}") includes;
    in
    "$CXX -x c++ program.code -o program.so -std=c++23 -O3 -fPIC -shared ${includeDirCmd}",
}:

{
  _type = "hullProblemTarget";

  __functor =
    self:
    {
      testCases,
      checker,
      validator,
      subtasks,
      includes,
      ...
    }@problem:

    let
      testCaseNames = builtins.sort builtins.lessThan (builtins.attrNames testCases);

      testCaseIndexes = builtins.listToAttrs (
        lib.imap1 (idx: name: {
          inherit name;
          value = idx;
        }) testCaseNames
      );

      configYamlContent = builtins.listToAttrs (
        lib.imap1 (
          idx: tcName:
          let
            tc = testCases.${tcName};
          in
          {
            name = (toString idx) + ".in";
            value = {
              timeLimit = builtins.floor (tc.tickLimit / ticksPerMs);
              memoryLimit = tc.memoryLimit / 1024;
              score = 100;
              subtaskId = 0;
              isPretest =
                (builtins.elem "sample" tc.groups)
                || (builtins.elem "sampleLarge" tc.groups)
                || (builtins.elem "pretest" tc.groups);
            };
          }
        ) testCaseNames
      );

      copyTestCasesCommand = lib.concatImapStringsSep "\n" (
        idx: tcName:
        let
          tc = testCases.${tcName};
        in
        ''
          cp ${tc.data.input} $data_dir/${toString idx}.in
          ${
            if outputName != null then "cp ${tc.data.outputs}/${outputName}" else "touch"
          } $data_dir/${toString idx}.ans
        ''
      ) testCaseNames;

      # Compile a C++ source file into an x86_64-linux-gnu shared library (.so).
      # This is the first step of the Luogu C++ standard workaround.
      compileShared =
        {
          programSrc,
          compileCommand,
          mode, # "checker" or "interactor" or "validator"
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
                      checker = "::cplib_initializers::testlib::checker::Initializer(false)";
                      extraIncludes = [ "\"${cplibInitializers}/include/testlib/checker.hpp\"" ];
                    }
                  else if mode == "checkerGraderInteraction" then
                    {
                      checker = "::cplib_initializers::luogu::checker_grader_interaction::Initializer()";
                      extraIncludes = [ "\"${cplibInitializers}/include/luogu/checker_grader_interaction.hpp\"" ];
                    }
                  else if mode == "interactor" then
                    {
                      interactor = "::cplib_initializers::testlib::interactor::Initializer(false)";
                      extraIncludes = [ "\"${cplibInitializers}/include/testlib/interactor.hpp\"" ];
                    }
                  else if mode == "validator" then
                    {
                      interactor = "::cplib_initializers::testlib::validator::Initializer()";
                      extraIncludes = [ "\"${cplibInitializers}/include/testlib/validator.hpp\"" ];
                    }
                  else
                    throw "Invalid mode `${mode}`"
                )
              );
        in
        pkgs.pkgsCross.gnu64.stdenv.mkDerivation {
          name = "hull-luoguCompiledShared-${problem.name}-${mode}";
          unpackPhase = ''
            cp ${patchedSrc} program.code
          '';
          buildPhase = ''
            runHook preBuild
            ${compileCommand includes}
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            install -Dm644 program.so $out/lib/x86_64-linux-gnu/program.so
            runHook postInstall
          '';
        };

      # Wrap a shared library into a C program by embedding it as a compressed,
      # base64-encoded string. This is the build-time part of the Luogu C++
      # standard workaround.
      wrapShared =
        wrapperName: shared:
        pkgs.runCommandLocal "hull-luoguWrappedShared-${wrapperName}.cpp"
          {
            nativeBuildInputs = [
              pkgs.qpdf
              pkgs.xxd
            ];
          }
          ''
            shared_so_path=${shared}/lib/x86_64-linux-gnu/program.so
            raw_so_size=$(wc -c $shared_so_path | cut -d' ' -f1)
            cat $shared_so_path | zlib-flate -compress=9 > shared-deflated.bin
            deflated_so_size=$(wc -c shared-deflated.bin | cut -d' ' -f1)
            base64 shared-deflated.bin -w0 > b64-content.txt
            awk \
              -v raw_size="$raw_so_size" \
              -v deflate_size="$deflated_so_size" \
              '
              BEGIN {
                getline b64 < "b64-content.txt"
              }
              {
                sub(/\/\* HULL_RAW_SO_SIZE \*\//, raw_size);
                sub(/\/\* HULL_DEFLATE_SO_SIZE \*\//, deflate_size);
                sub(/HULL_B64_STR/, b64);
                print;
              }
              ' ${./sharedWrapper.c} > $out
          '';

      wrappedChecker = wrapShared "checker" (compileShared {
        programSrc = checker.src;
        compileCommand = checkerCompileCommand;
        mode =
          if type == "stdioInteraction" then
            "interactor"
          else if graderSrc != null then
            "checkerGraderInteraction"
          else
            "checker";
      });

      wrappedValidator = wrapShared "validator" (compileShared {
        programSrc = validator.src;
        compileCommand = validatorCompileCommand;
        mode = "validator";
      });

      scoringScriptContent = ''
        @final_status = AC;
        @total_score = 0;
        @final_time = 0;
        @final_memory = 0;
      ''
      + (lib.concatMapStringsSep "\n" (idx: ''
        if @status${toString idx} != AC; then
          @final_status = UNAC;
        fi
        if @time${toString idx} > @final_time; then
          @final_time = @time${toString idx};
        fi
        if @memory${toString idx} > @final_memory; then
          @final_memory = @memory${toString idx};
        fi
      '') (lib.range 1 (builtins.length testCaseNames)))
      + (lib.concatLines (
        lib.imap0 (
          stIdx: st:
          let
            stScore = builtins.floor (st.fullScore * scoreScale);
          in
          if st.scoringMethod == "min" then
            ''
              @hull_st${toString stIdx}_score = ${toString stScore};
              ${lib.concatMapStringsSep "\n" (
                tc:
                let
                  tcIdx = testCaseIndexes.${toString tc.name};
                in
                ''
                  @hull_tmp = @score${toString tcIdx} * ${toString stScore} / 100;
                  if @hull_tmp < @hull_st${toString stIdx}_score; then
                    @hull_st${toString stIdx}_score = @hull_tmp;
                  fi
                ''
              ) st.testCases}
              @total_score = @total_score + @hull_st${toString stIdx}_score;
            ''
          else
            lib.concatMapStringsSep "\n" (
              tc:
              let
                tcIdx = testCaseIndexes.${tc.name};
              in
              ''
                @hull_tmp = @score${toString tcIdx} * ${toString stScore} / ${
                  toString (100 * (builtins.length st.testCases))
                };
                @total_score = @total_score + @hull_tmp;
              ''
            ) st.testCases
        ) subtasks
      ));

      requiredTags = [
        "Special Judge"
        "O2优化" # O2 Optimization
      ]
      ++ (lib.optional (type == "stdioInteraction") "交互题") # Interactive Problem
      ++ (lib.optional (type == "answerOnly") "提交答案"); # Answer Only

    in
    pkgs.runCommandLocal "hull-problemTargetOutput-${problem.name}-luogu"
      { nativeBuildInputs = [ pkgs.zip ]; }
      ''
        mkdir $out
        data_dir=$(mktemp -d)

        echo ${lib.escapeShellArg (builtins.toJSON configYamlContent)} > $data_dir/config.yml

        cp ${wrappedChecker} $data_dir/checker.cpp
        cp ${wrappedValidator} $data_dir/validator.cpp
        ${if graderSrc != null then "cp ${graderSrc}" else "touch"} $data_dir/interactive_lib.cpp

        ${copyTestCasesCommand}

        # Luogu's zip size limit is 50 MiB, so `-9` is needed to compress better.
        (cd $data_dir && zip -9 -r $out/data.zip .)

        echo ${lib.escapeShellArg scoringScriptContent} > $out/scoring-script.txt
        echo ${lib.escapeShellArg (builtins.toJSON requiredTags)} > $out/required-tags.json
      '';
}
