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
  pkgs,
  hull,
  hullPkgs,
}:

{
  # Whether to emit a single zip archive or an unpacked directory tree.
  zipped ? true,

  # Conversion ratio from Hull ticks to UOJ milliseconds in result.txt.
  ticksPerMs ? 1.0e7,

  # Number of testcase judging threads used by uojCustom.
  # 0 means auto-detect based on available_parallelism().
  judgerThreads ? 0,

  # Mapping from UOJ language names to Hull language identifiers.
  # null means the UOJ language is explicitly unsupported by uojCustom.
  uojToHullLanguageMap ? {
    "C" = "c.23.s64m";
    "C89" = "c.89.s64m";
    "C99" = "c.99.s64m";
    "C11" = "c.11.s64m";
    "C17" = "c.17.s64m";
    "C23" = "c.23.s64m";
    "C++" = "cpp.26.s64m";
    "C++98" = "cpp.98.s64m";
    "C++03" = "cpp.03.s64m";
    "C++11" = "cpp.11.s64m";
    "C++14" = "cpp.14.s64m";
    "C++17" = "cpp.17.s64m";
    "C++20" = "cpp.20.s64m";
    "C++23" = "cpp.23.s64m";
    "C++26" = "cpp.26.s64m";
  },
}:

{
  _type = "hullProblemTarget";
  __functor =
    self:
    {
      documents,
      checker,
      validator,
      generators,
      solutions,
      testCases,
      ...
    }@problem:
    let
      nixUserChroot = hullPkgs.nix-user-chroot;
      allTestCases = builtins.attrValues testCases;

      metadata = {
        name = problem.name;
        tickLimit = problem.tickLimit;
        memoryLimit = problem.memoryLimit;
        fullScore = problem.fullScore;
        checker = {
          src = null;
          wasm = {
            path = builtins.unsafeDiscardStringContext (toString problem.checker.wasm);
            drvPath = null;
          };
        };
        validator = {
          src = null;
          wasm = {
            path = builtins.unsafeDiscardStringContext (toString problem.validator.wasm);
            drvPath = null;
          };
        };
        judger = {
          prepareSolutionRunner = {
            path = builtins.unsafeDiscardStringContext (lib.getExe problem.judger.prepareSolution);
            drvPath = null;
          };
          generateOutputsRunner = {
            path = builtins.unsafeDiscardStringContext (lib.getExe problem.judger.generateOutputs);
            drvPath = null;
          };
          judgeRunner = {
            path = builtins.unsafeDiscardStringContext (lib.getExe problem.judger.judge);
            drvPath = null;
          };
        };
        mainCorrectSolution = problem.mainCorrectSolution.name;
        testCases = map (tc: {
          name = tc.name;
          tickLimit = tc.tickLimit;
          memoryLimit = tc.memoryLimit;
          groups = tc.groups;
          traitHints = tc.traitHints;
        }) allTestCases;
        subtasks = map (st: {
          fullScore = st.fullScore;
          scoringMethod = st.scoringMethod;
          traits = st.traits;
        }) problem.subtasks;
        solutions = map (solution: {
          name = solution.name;
          src = "solutions/${baseNameOf (toString solution.src)}";
          mainCorrectSolution = solution.mainCorrectSolution;
          participantVisibility = solution.participantVisibility;
        }) (builtins.attrValues problem.solutions);
      };

      mkOfficialDataArchive =
        tc:
        pkgs.runCommandLocal "hull-uojCustom-official-data-${problem.name}-${tc.name}.tar" { } ''
            tmpdir=$(mktemp -d)
            cleanup() {
              rm -rf "$tmpdir"
            }
            trap cleanup EXIT

          mkdir -p "$tmpdir/outputs"
          cp ${
            pkgs.writeText "${tc.name}-official-data-metadata.json" (
              builtins.toJSON { testCaseName = tc.name; }
            )
          } "$tmpdir/official-data-metadata.json"
          cp ${pkgs.writeText "${tc.name}-input-validation.json" (builtins.toJSON tc.inputValidation)} "$tmpdir/validation.json"
          cp -r ${tc.data.outputs}/. "$tmpdir/outputs/"
          tar -C "$tmpdir" -cf "$out" official-data-metadata.json validation.json outputs
        '';

      judgeBundleData = pkgs.runCommandLocal "hull-uojCustom-data-${problem.name}" { } ''
        mkdir -p $out/data $out/solutions
        cp ${pkgs.writeText "hull-uojCustom-${problem.name}.json" (builtins.toJSON metadata)} \
          $out/problem.json
        cp ${
          pkgs.writeText "hull-uojCustom-language-config-${problem.name}.json" (
            builtins.toJSON {
              uojToHullLanguageMap = uojToHullLanguageMap;
            }
          )
        } $out/uoj-custom-language-config.json
        ${lib.concatMapStringsSep "\n" (
          tc:
          let
            pathPrefix = "$out/data/${tc.name}";
          in
          ''
            mkdir -p ${pathPrefix}
            cp ${tc.data.input} ${pathPrefix}/input
            cp ${mkOfficialDataArchive tc} ${pathPrefix}/official-data.tar
          ''
        ) allTestCases}
        ${lib.concatMapStringsSep "\n" (solution: ''
          cp ${solution.src} $out/solutions/${baseNameOf (toString solution.src)}
        '') (builtins.attrValues problem.solutions)}
      '';

      nixUserChrootStorePath = builtins.unsafeDiscardStringContext (toString nixUserChroot);
      nixUserChrootRelative = "/nix/store/${baseNameOf nixUserChrootStorePath}/bin/nix-user-chroot";
      customJudgeRunner = pkgs.writeShellScriptBin "hull-uoj-custom-judge-runner-${problem.name}" ''
        bundle_root="$1"
        submission_file="$2"
        submission_language="$3"
        uoj_work_path="$4"
        uoj_result_path="$5"
        uoj_data_path="$6"
        exec ${lib.getExe hullPkgs.default} uoj-custom-judge \
          --bundle-root "$bundle_root" \
          --metadata-path "problem.json" \
          --submission-file "$submission_file" \
          --submission-language "$submission_language" \
          --uoj-work-path "$uoj_work_path" \
          --uoj-result-path "$uoj_result_path" \
          --uoj-data-path "$uoj_data_path" \
          --threads ${toString judgerThreads} \
          --ticks-per-ms ${toString ticksPerMs}
      '';

      customJudgeRunnerStorePath = builtins.unsafeDiscardStringContext (toString customJudgeRunner);
      customJudgeRunnerRelative = "/nix/store/${baseNameOf customJudgeRunnerStorePath}/bin/hull-uoj-custom-judge-runner-${problem.name}";

      targetClosure = pkgs.closureInfo {
        rootPaths = [
          customJudgeRunner
          hullPkgs.default
          hullPkgs.wasm32-wasi-wasip1.clang
          nixUserChroot
          problem.checker.wasm
          problem.validator.wasm
          problem.judger.prepareSolution
          problem.judger.generateOutputs
          problem.judger.judge
        ];
      };

      problemConf = ''
        use_builtin_judger off
        n_tests ${toString (builtins.length allTestCases)}
        n_ex_tests 0
        n_sample_tests 0
        input_pre input
        input_suf txt
        output_pre output
        output_suf txt
        judger_time_limit 1048576
        judger_memory_limit 1048576
        judger_output_limit 2047
      '';

      judgerShellScript = pkgs.replaceVarsWith {
        src = ./judger.sh.in;
        replacements = {
          NIX_USER_CHROOT_STORE_SUFFIX = lib.removePrefix "/nix/store" nixUserChrootRelative;
          CUSTOM_JUDGE_RUNNER_RELATIVE = customJudgeRunnerRelative;
        };
      };

      mkDocumentsCopyCommand =
        pathPrefix: docs:
        let
          visible = builtins.any ({ participantVisibility, ... }: participantVisibility) (
            builtins.attrValues docs
          );
        in
        lib.optionalString visible ''
          mkdir -p ${pathPrefix}
          ${lib.concatMapAttrsStringSep "\n" (
            name: doc: lib.optionalString doc.participantVisibility "cp ${doc.path} ${pathPrefix}/${name}"
          ) docs}
        '';
    in
    pkgs.runCommandLocal
      ("hull-problemTargetOutput-${problem.name}-uojCustom" + lib.optionalString zipped ".zip")
      {
        nativeBuildInputs = [ pkgs._7zz ];
      }
      ''
        tmpdir=$(mktemp -d)
        cleanup() {
          rm -rf "$tmpdir"
        }
        trap cleanup EXIT

        mkdir -p "$tmpdir/download/document"
        mkdir -p "$tmpdir/hull-bundle/nix/store"

        while IFS= read -r store_path; do
          cp -a --no-preserve=ownership "$store_path" "$tmpdir/hull-bundle/nix/store/"
        done < ${targetClosure}/store-paths

        cp -r ${judgeBundleData}/. "$tmpdir/hull-bundle/"
        chmod -R u+rwX "$tmpdir/hull-bundle"
        tar -C "$tmpdir/hull-bundle/nix" -cJf "$tmpdir/hull-bundle/nix-store.tar.xz" store
        rm -rf "$tmpdir/hull-bundle/nix/store"
        cp ${pkgs.writeText "problem.conf" problemConf} "$tmpdir/problem.conf"
        cp ${./judger.mk} "$tmpdir/Makefile"
        cp ${./judger.c} "$tmpdir/judger.c"
        cp ${judgerShellScript} "$tmpdir/judger.sh"
        cp ${./README.txt} "$tmpdir/README.txt"

        ${mkDocumentsCopyCommand "$tmpdir/download/document" documents}

        ${
          if zipped then
            ''
              (
                cd "$tmpdir"
                7zz a -tzip -mx=9 -mmt=on "$out" . -x!hull-bundle/nix-store.tar.xz
                7zz a -tzip -mx=0 "$out" hull-bundle/nix-store.tar.xz
              )
            ''
          else
            ''
              mkdir "$out"
              cp -r "$tmpdir"/. "$out/"
            ''
        }
      '';
}
