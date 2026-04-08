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
  targetHullPkgsForSystem,
  targetPkgsForSystem,
  targetHullForSystem,
}:

{
  # Target system used to retarget bundled Hull runtime artifacts.
  targetSystem ? builtins.currentSystem,
  # Score multiplier applied when mapping Hull scores to Lemon integer scores.
  scoreScale ? 100.0,
  # Conversion factor from Hull ticks to Lemon displayed milliseconds.
  ticksPerMs ? 1.0e7,
  # Mapping from solution name to source extension used in Lemon contestant folders.
  solutionExtNames ? { },
  # Lemon compiler name expected by imported task compilerConfiguration entries.
  compilerName ? "HullBundle",
  # Lemon compiler configuration name expected by imported task compilerConfiguration entries.
  compilerConfigurationName ? "default",
  # Mapping from Lemon source extension to Hull language.
  lemonToHullLanguageMap ? {
    c = "c.23.s64m";
    cpp = "cpp.26.s64m";
  },
}:

{
  _type = "hullProblemTarget";
  __functor =
    self:
    {
      testCases,
      subtasks,
      solutions,
      documents,
      ...
    }@problem:
    let
      lemonWatcherTimeLimitMs = 1000 * 60 * 60 * 24;
      targetHullPkgs = targetHullPkgsForSystem targetSystem;
      targetPkgs = targetPkgsForSystem targetSystem;
      targetHull = targetHullForSystem targetSystem;
      nixUserChroot = targetHullPkgs.nix-user-chroot;
      retargetRunner =
        runner:
        if runner ? retarget then
          runner.retarget {
            inherit targetPkgs targetHullPkgs targetHull;
          }
        else
          runner;
      targetJudger = {
        prepareSolution = retargetRunner problem.judger.prepareSolution;
        generateOutputs = retargetRunner problem.judger.generateOutputs;
        judge = retargetRunner problem.judger.judge;
      };
      allTestCases = builtins.attrValues testCases;

      metadata = {
        inherit (problem)
          name
          tickLimit
          memoryLimit
          fullScore
          ;
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
            path = builtins.unsafeDiscardStringContext (lib.getExe targetJudger.prepareSolution);
            drvPath = null;
          };
          generateOutputsRunner = {
            path = builtins.unsafeDiscardStringContext (lib.getExe targetJudger.generateOutputs);
            drvPath = null;
          };
          judgeRunner = {
            path = builtins.unsafeDiscardStringContext (lib.getExe targetJudger.judge);
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
        pkgs.runCommandLocal "hull-lemonCustom-officialData-${problem.name}-${tc.name}.tar" { } ''
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

      judgeBundleData = pkgs.runCommandLocal "hull-lemonCustom-data-${problem.name}" { } ''
        mkdir -p $out/data/${problem.name} $out/solutions
        cp ${pkgs.writeText "hull-lemonCustom-${problem.name}.json" (builtins.toJSON metadata)} \
          $out/data/${problem.name}/problem.json
        cp ${
          pkgs.writeText "hull-lemon-language-map-${problem.name}.json" (
            builtins.toJSON {
              lemonToHullLanguageMap = lemonToHullLanguageMap;
            }
          )
        } $out/data/${problem.name}/lemon-language-map.json
        ${lib.concatMapStringsSep "\n" (
          tc:
          let
            pathPrefix = "$out/data/${problem.name}/${tc.name}";
          in
          ''
            mkdir -p ${pathPrefix}
            cp ${tc.data.input} ${pathPrefix}/input
            cp ${mkOfficialDataArchive tc} ${pathPrefix}/official-data.tar
            printf '%s\n' ${toString tc.tickLimit} > ${pathPrefix}/tick-limit
            printf '%s\n' ${toString tc.memoryLimit} > ${pathPrefix}/memory-limit
          ''
        ) allTestCases}
        ${lib.concatMapStringsSep "\n" (solution: ''
          cp ${solution.src} $out/solutions/${baseNameOf (toString solution.src)}
        '') (builtins.attrValues problem.solutions)}
      '';

      customJudgeRunner = targetPkgs.writeShellScriptBin "hull-lemon-custom-judge-runner-${problem.name}" ''
        exec ${lib.getExe targetHullPkgs.default} lemon-custom-judge "$@"
      '';

      targetClosure = pkgs.closureInfo {
        rootPaths = [
          customJudgeRunner
          targetHullPkgs.default
          targetHullPkgs.wasm32-wasi-wasip1.clang
          nixUserChroot
          problem.checker.wasm
          problem.validator.wasm
          targetJudger.prepareSolution
          targetJudger.generateOutputs
          targetJudger.judge
        ];
      };

      lemonTestCases =
        let
          subtasksWithIndex = lib.imap0 (index: st: { inherit index st; }) subtasks;
        in
        lib.concatMap (
          { index, st }:
          if st.scoringMethod == "sum" then
            let
              numTestCases = builtins.length st.testCases;
              scorePerCase = if numTestCases > 0 then st.fullScore / numTestCases else 0;
            in
            map (tc: {
              fullScore = builtins.floor (scorePerCase * scoreScale);
              timeLimit = lemonWatcherTimeLimitMs;
              memoryLimit = 16777216;
              inputFiles = [ "${problem.name}/${tc.name}/input" ];
              outputFiles = [ "${problem.name}/${tc.name}/official-data.tar" ];
            }) st.testCases
          else
            [
              {
                fullScore = builtins.floor (st.fullScore * scoreScale);
                timeLimit = lemonWatcherTimeLimitMs;
                memoryLimit = 16777216;
                inputFiles = map (tc: "${problem.name}/${tc.name}/input") st.testCases;
                outputFiles = map (tc: "${problem.name}/${tc.name}/official-data.tar") st.testCases;
              }
            ]
        ) subtasksWithIndex;

      lemonJsonContent = {
        version = "1.0";
        contestTitle = problem.name;
        tasks = [
          {
            problemTitle = problem.name;
            sourceFileName = problem.name;
            inputFileName = "${problem.name}.in";
            outputFileName = "${problem.name}.out";
            standardInputCheck = true;
            standardOutputCheck = false;
            subFolderCheck = true;
            comparisonMode = 4;
            specialJudge = "_hull/lemon-special-judge";
            taskType = 0;
            compilerConfiguration = {
              "${compilerName}" = compilerConfigurationName;
            };
            testCases = lemonTestCases;
          }
        ];
        contestants = lib.mapAttrsToList (solName: _: {
          contestantName = solName;
          checkJudged = [ false ];
          compileState = [ 1 ];
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

      nixUserChrootStorePath = builtins.unsafeDiscardStringContext (toString nixUserChroot);
      nixUserChrootRelative = "/nix/store/${baseNameOf nixUserChrootStorePath}/bin/nix-user-chroot";
      bundleJudgeRunnerRelative = "/nix/store/${baseNameOf (builtins.unsafeDiscardStringContext (toString customJudgeRunner))}/bin/hull-lemon-custom-judge-runner-${problem.name}";

      staticStdenv =
        (if targetSystem == builtins.currentSystem then pkgs else targetPkgs).pkgsStatic.stdenv;
      staticPkgs = (if targetSystem == builtins.currentSystem then pkgs else targetPkgs).pkgsStatic;

      watcherSource = pkgs.replaceVarsWith {
        src = ./watcher.c;
        replacements = {
          NIX_USER_CHROOT_STORE_SUFFIX = lib.removePrefix "/nix/store" nixUserChrootRelative;
          CUSTOM_JUDGE_RUNNER_RELATIVE = bundleJudgeRunnerRelative;
          TICKS_PER_MS = toString ticksPerMs;
        };
      };

      compiledWatcher = staticStdenv.mkDerivation {
        name = "hull-lemonCustomWatcher-${problem.name}";
        src = watcherSource;
        dontUnpack = true;
        nativeBuildInputs = [
          staticPkgs.pkg-config
        ];
        buildInputs = [
          staticPkgs.libarchive
        ];
        buildPhase = ''
          $CC -x c -static -O3 "$src" -o lemon-custom-watcher \
            $($PKG_CONFIG --cflags libarchive) \
            $($PKG_CONFIG --libs --static libarchive)
        '';
        installPhase = ''
          mkdir -p $out/bin
          cp lemon-custom-watcher $out/bin/lemon-custom-watcher
        '';
      };

      lemonCompilerScript = pkgs.writeShellScript "hull-lemonCustom-compiler-${problem.name}" ''
        set -eu
        if [ "$#" -ne 1 ]; then
          printf 'expected exactly one source file, got %s\n' "$#" >&2
          exit 1
        fi
        self_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
        data_root=$(CDPATH= cd -- "$self_dir/.." && pwd)
        src="$1"
        base="''${src%.*}"
        problem_name=$(basename "$base")
        if [ ! -d "$data_root/$problem_name" ]; then
          printf 'missing lemonCustom problem bundle: %s\n' "$data_root/$problem_name" >&2
          exit 1
        fi
        tmpdir=$(mktemp -d)
        cleanup() {
          chmod -R u+rwX "$tmpdir" 2>/dev/null || true
          rm -rf "$tmpdir"
        }
        trap cleanup EXIT
        mkdir -p "$tmpdir/root"
        mkdir -p "$tmpdir/root/bundle" "$tmpdir/root/runtime-nix/store"
        cp -r "$data_root/$problem_name"/. "$tmpdir/root/bundle/"
        printf '%s\n' "$problem_name" > "$tmpdir/root/problem-name"
        cp -RL --no-preserve=ownership "$data_root/_hull/nix/store"/. "$tmpdir/root/runtime-nix/store/"
        submission_name=$(basename "$src")
        printf '%s\n' "$submission_name" > "$tmpdir/root/submission-name"
        cp "$src" "$tmpdir/root/$submission_name"
        tar -C "$tmpdir/root" -cf "$base.hullbundle" .
      '';

      lemonSpecialJudgeScript = pkgs.writeText "hull-lemonCustom-specialJudge-${problem.name}" ''
        #!/bin/sh
        set -eu
        input_path="$1"
        contestant_output="$2"
        answer_path="$3"
        full_score="$4"
        score_path="$5"
        message_path="$6"
        report_path="$contestant_output.hull-report.json"
        if [ ! -f "$contestant_output" ]; then
          : > "$contestant_output"
        fi
        if [ ! -f "$report_path" ]; then
          printf '0\n' > "$score_path"
          printf 'missing hull report: %s\n' "$report_path" > "$message_path"
          exit 0
        fi
        score=$( ${lib.getExe pkgs.jq} -r --argjson fullScore "$full_score" '(.score * $fullScore) | floor' "$report_path" )
        message=$( ${lib.getExe pkgs.jq} -r 'if .message == "" then .status else (.status + ": " + .message) end' "$report_path" )
        printf '%s\n' "$score" > "$score_path"
        printf '%s\n' "$message" > "$message_path"
      '';

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
    pkgs.runCommandLocal "hull-problemTargetOutput-${problem.name}-lemonCustom" { } ''
      mkdir -p $out/data/${problem.name} $out/data/_hull/nix/store $out/source

      while IFS= read -r store_path; do
        cp -a --no-preserve=ownership "$store_path" "$out/data/_hull/nix/store/"
      done < ${targetClosure}/store-paths

      cp -r ${judgeBundleData}/data/${problem.name}/. $out/data/${problem.name}/
      cp ${lemonCompilerScript} $out/data/_hull/lemon-custom-compiler
      chmod +x $out/data/_hull/lemon-custom-compiler
      cp ${compiledWatcher}/bin/lemon-custom-watcher $out/data/_hull/lemon-custom-watcher
      chmod +x $out/data/_hull/lemon-custom-watcher
      cp ${lemonSpecialJudgeScript} $out/data/_hull/lemon-special-judge
      chmod +x $out/data/_hull/lemon-special-judge

      echo '${builtins.toJSON lemonJsonContent}' > $out/${problem.name}.cdf

      ${lib.concatMapAttrsStringSep "\n" (solName: ext: ''
        mkdir -p $out/source/${solName}/${problem.name}
        cp ${solutions.${solName}.src} $out/source/${solName}/${problem.name}/${problem.name}.${ext}
      '') solutionExtNames}

      ${mkDocumentsCopyCommand "$out/document" documents}
    '';
}
