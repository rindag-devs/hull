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
  # System used to build the bundled runtime tools.
  targetSystem ? builtins.currentSystem,

  # Score multiplier written into Hydro's single testcase config.
  scoreScale ? 100.0,

  # Statement files keyed by display language.
  statements ? { },

  # Default statement language for Hydro metadata.
  defaultDisplayLanguage ? "en",

  # Problem owner used in problem.yaml.
  owner ? 0,

  # Problem tags used in problem.yaml.
  tag ? [ ],

  # Whether to emit a single zip archive or an unpacked directory tree.
  zipped ? true,

  # Tick-to-millisecond conversion used for Hydro config.yaml.
  ticksPerMs ? 1.0e7,

  # Mapping from Hydro language ids to Hull language identifiers.
  hydroToHullLanguageMap ? {
    c.c99 = "c.99.s64m";
    c.c99o2 = "c.99.s64m";
    c.c99o3 = "c.99.s64m";
    c.c11 = "c.11.s64m";
    c.c11o2 = "c.11.s64m";
    c.c11o3 = "c.11.s64m";
    c.c17 = "c.17.s64m";
    c.c17o2 = "c.17.s64m";
    c.c17o3 = "c.17.s64m";
    c.c23 = "c.23.s64m";
    c.c23o2 = "c.23.s64m";
    c.c23o3 = "c.23.s64m";
    cc.cc11 = "cpp.11.s64m";
    cc.cc11o2 = "cpp.11.s64m";
    cc.cc11o3 = "cpp.11.s64m";
    cc.cc14 = "cpp.14.s64m";
    cc.cc14o2 = "cpp.14.s64m";
    cc.cc14o3 = "cpp.14.s64m";
    cc.cc17 = "cpp.17.s64m";
    cc.cc17o2 = "cpp.17.s64m";
    cc.cc17o3 = "cpp.17.s64m";
    cc.cc20 = "cpp.20.s64m";
    cc.cc20o2 = "cpp.20.s64m";
    cc.cc20o3 = "cpp.20.s64m";
    cc.cc23 = "cpp.23.s64m";
    cc.cc23o2 = "cpp.23.s64m";
    cc.cc23o3 = "cpp.23.s64m";
    cc.cc26 = "cpp.26.s64m";
    cc.cc26o2 = "cpp.26.s64m";
    cc.cc26o3 = "cpp.26.s64m";
  },

  # Participant solution label shown in bundled Hull reports.
  participantSolutionName ? "hydroCustom",

  # Number of internal testcase judging threads. 0 means auto-detect.
  judgerThreads ? 0,

  # Time limit of judge.sh itsef.
  # Hydro mandates a time limit for all problems, which applies to `judge.sh` itself.
  # Set it large enough to ensure all test cases can be evaluated within this duration.
  judgerTimeLimitMs ? 60000,

  # Memory limit of judge.sh itsef.
  # The outer Hydro testcase only wraps Hull's own runtime, so use a large
  # installation-level limit rather than the problem's per-case memory cap.
  judgerMeroryLimitMiB ? 2048,

  # Optional Hydro language allowlist written to config.yaml.
  allowedLanguages ? null,
}:

{
  _type = "hullProblemTarget";
  __functor =
    self:
    {
      displayName,
      testCases,
      subtasks,
      documents,
      solutions,
      ...
    }@problem:
    let
      targetHullPkgs = targetHullPkgsForSystem targetSystem;
      targetPkgs = targetPkgsForSystem targetSystem;
      targetHull = targetHullForSystem targetSystem;
      proot = hullPkgs.proot-static;
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
      flattenedHydroToHullLanguageMap = lib.concatMapAttrs (
        family: variants:
        lib.mapAttrs' (variant: hullLang: {
          name = "${family}.${variant}";
          value = hullLang;
        }) variants
      ) hydroToHullLanguageMap;
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
        pkgs.runCommandLocal "hull-hydroCustom-officialData-${problem.name}-${tc.name}.tar" { } ''
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

      judgeBundleArchive = pkgs.runCommandLocal "hull-hydroCustom-bundle-${problem.name}.tar.xz" { } ''
        tmpdir=$(mktemp -d)
        cleanup() {
          chmod -R u+rwX "$tmpdir" 2>/dev/null || true
          rm -rf "$tmpdir"
        }
        trap cleanup EXIT

        mkdir -p "$tmpdir/bundle/solutions"
        cp ${pkgs.writeText "hull-hydroCustom-${problem.name}.json" (builtins.toJSON metadata)} \
          "$tmpdir/bundle/problem.json"
        cp ${
          pkgs.writeText "hull-hydroCustom-languageMap-${problem.name}.json" (
            builtins.toJSON {
              hydroToHullLanguageMap = flattenedHydroToHullLanguageMap;
            }
          )
        } "$tmpdir/bundle/hydro-language-map.json"
        ${lib.concatMapStringsSep "\n" (
          tc:
          let
            pathPrefix = "$tmpdir/bundle/${tc.name}";
          in
          ''
            mkdir -p ${pathPrefix}
            cp ${tc.data.input} ${pathPrefix}/input
            cp ${mkOfficialDataArchive tc} ${pathPrefix}/official-data.tar
          ''
        ) allTestCases}
        ${lib.concatMapStringsSep "\n" (solution: ''
          cp ${solution.src} "$tmpdir/bundle/solutions/${baseNameOf (toString solution.src)}"
        '') (builtins.attrValues problem.solutions)}

        tar -C "$tmpdir" -cJf "$out" bundle
      '';

      targetClosure = pkgs.closureInfo {
        rootPaths = [
          targetHullPkgs.default
          targetHullPkgs.wasm32-wasi-wasip1.clang
          problem.checker.wasm
          problem.validator.wasm
          targetJudger.prepareSolution
          targetJudger.generateOutputs
          targetJudger.judge
        ];
      };

      runtimeStoreArchive =
        pkgs.runCommandLocal "hull-hydroCustom-runtimeStore-${problem.name}.tar.xz" { }
          ''
            tmpdir=$(mktemp -d)
            cleanup() {
              chmod -R u+rwX "$tmpdir" 2>/dev/null || true
              rm -rf "$tmpdir"
            }
            trap cleanup EXIT

            mkdir -p "$tmpdir/nix/store"
            while IFS= read -r store_path; do
              cp -a --no-preserve=ownership "$store_path" "$tmpdir/nix/store/"
              chmod -R u+w "$tmpdir/nix/store/$(basename "$store_path")" 2>/dev/null || true
            done < ${targetClosure}/store-paths

            tar -C "$tmpdir" -cJf "$out" nix
          '';

      problemYamlContent = {
        title = displayName.${defaultDisplayLanguage} or problem.name;
        inherit owner tag;
      };

      configYamlContent = {
        type = "default";
        time = "${toString judgerTimeLimitMs}ms";
        memory = "${toString judgerMeroryLimitMiB}m";
        subtasks = [
          {
            id = 1;
            score = builtins.floor (problem.fullScore * scoreScale);
            type = "sum";
            cases = [
              {
                input = "hull.in";
                output = "hull.ans";
              }
            ];
          }
        ];
        checker = {
          file = "checker.c";
          lang = "c";
        };
        checker_type = "lemon";
        user_extra_files = [
          "compile.sh"
          "execute.sh"
          "proot"
          "hull-bundle.tar.xz"
          "hull-runtime-store.tar.xz"
        ];
        judge_extra_files = [ ];
      }
      // lib.optionalAttrs (allowedLanguages != null) { langs = allowedLanguages; };

      compileSh = pkgs.writeTextFile {
        name = "hull-hydroCustom-compile-${problem.name}";
        executable = true;
        text = ''
          #!/bin/sh
          set -eu
          self_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
          lang_suffix=''${HYDRO_LANG#*.}
          src="foo.$lang_suffix"
          if [ ! -f "$src" ]; then
            set -- foo.*
            if [ "$1" != 'foo.*' ]; then
              src="$1"
            fi
          fi
          if [ ! -f "$src" ]; then
            printf 'missing Hydro submission source\n' >&2
            exit 1
          fi
          tmpdir=$(mktemp -d)
          cleanup() {
            chmod -R u+rwX "$tmpdir" 2>/dev/null || true
            rm -rf "$tmpdir"
          }
          trap cleanup EXIT
          mkdir -p "$tmpdir/root"
          submission_name=$(basename "$src")
          printf '%s\n' "$submission_name" > "$tmpdir/root/submission-name"
          printf '%s\n' "$HYDRO_LANG" > "$tmpdir/root/submission-language"
          cp "$src" "$tmpdir/root/$submission_name"
          tar -C "$tmpdir/root" -cf foo .
        '';
        checkPhase = ''
          ${pkgs.stdenv.shellDryRun} "$target"
        '';
      };

      executeSh = pkgs.writeTextFile {
        name = "hull-hydroCustom-execute-${problem.name}";
        executable = true;
        text = ''
          #!/bin/sh
          set -eu
          self_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
          bundle_path="foo"
          tmpdir=$(mktemp -d)
          cleanup() {
            chmod -R u+rwX "$tmpdir" 2>/dev/null || true
            rm -rf "$tmpdir"
          }
          trap cleanup EXIT
          extract_root="$tmpdir/extract"
          mkdir -p "$extract_root"
          tar -C "$extract_root" -xf "$bundle_path"
          mkdir -p "$extract_root/bundle-root" "$extract_root/runtime-root"
          tar -C "$extract_root" --no-same-owner -xJf "$self_dir/hull-bundle.tar.xz"
          tar -C "$extract_root/runtime-root" --no-same-owner -xJf "$self_dir/hull-runtime-store.tar.xz"
          stdout_report="$extract_root/stdout-report.txt"
          submission_language=$(cat "$extract_root/submission-language")
          "$self_dir/proot" \
            -b "$extract_root/runtime-root/nix:/nix" \
            -b "$extract_root:/bundle-host" \
            -b "$extract_root/bundle:/bundle" \
            "${lib.getExe targetHullPkgs.default}" hydro-custom-judge \
            --bundle-root /bundle \
            --metadata-path problem.json \
            --submission-file "/bundle-host/$(cat "$extract_root/submission-name")" \
            --submission-language "$submission_language" \
            --language-map-path hydro-language-map.json \
            --participant-solution-name ${participantSolutionName} \
            --stdout-report-path /bundle-host/stdout-report.txt \
            --threads ${toString judgerThreads}
          cat "$stdout_report"
        '';
        checkPhase = ''
          ${pkgs.stdenv.shellDryRun} "$target"
        '';
      };

      documentsCommand = lib.concatMapAttrsStringSep "\n" (docName: doc: ''
        cp ${doc.path} $tmpdir/additional_file/document_${docName}
      '') (lib.filterAttrs (_: doc: doc.participantVisibility) documents);

      statementsCommand = lib.concatMapAttrsStringSep "\n" (lang: docName: ''
        printf '%s\n' '@[PDF](file://document_${docName})' > $tmpdir/problem_${lang}.md
      '') statements;
    in
    pkgs.runCommandLocal
      ("hull-problemTargetOutput-${problem.name}-hydroCustom" + (lib.optionalString zipped ".zip"))
      {
        nativeBuildInputs = [ pkgs._7zz ];
      }
      ''
        tmpdir=$(mktemp -d)
        cleanup() {
          chmod -R u+rwX "$tmpdir" 2>/dev/null || true
          rm -rf "$tmpdir"
        }
        trap cleanup EXIT

        mkdir -p "$tmpdir/additional_file" "$tmpdir/testdata"

        echo ${lib.escapeShellArg (builtins.toJSON problemYamlContent)} > "$tmpdir/problem.yaml"
        echo ${lib.escapeShellArg (builtins.toJSON configYamlContent)} > "$tmpdir/testdata/config.yaml"

        cp ${judgeBundleArchive} "$tmpdir/testdata/hull-bundle.tar.xz"
        cp ${runtimeStoreArchive} "$tmpdir/testdata/hull-runtime-store.tar.xz"
        cp ${proot}/bin/proot "$tmpdir/testdata/proot"
        : > "$tmpdir/testdata/hull.in"
        : > "$tmpdir/testdata/hull.ans"
        cp ${compileSh} "$tmpdir/testdata/compile.sh"
        cp ${executeSh} "$tmpdir/testdata/execute.sh"
        chmod +x "$tmpdir/testdata/compile.sh" "$tmpdir/testdata/execute.sh" "$tmpdir/testdata/proot"
        cp ${./checker.c} "$tmpdir/testdata/checker.c"

        ${documentsCommand}
        ${statementsCommand}

        ${hull.problemTarget.utils.samplesCommand {
          inherit problem;
          outputName = "output";
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

        ${
          if zipped then
            ''
              (
                cd "$tmpdir"
                7zz a -tzip -mx=9 -mmt=on "$out" . -x!testdata/hull-bundle.tar.xz -x!testdata/hull-runtime-store.tar.xz
                7zz a -tzip -mx=0 "$out" testdata/hull-bundle.tar.xz testdata/hull-runtime-store.tar.xz
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
