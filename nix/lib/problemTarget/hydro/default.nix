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

  # Zstandard compression level used for tar.zst archives.
  zstdCompressionLevel ? 19,

  # ZIP compression level used for the outer archive.
  zipCompressionLevel ? 9,

  # Tick-to-millisecond conversion used for Hydro config.yaml.
  ticksPerMs ? 1.0e7,

  # Mapping from Hydro language ids to Hull language identifiers.
  hydroToHullLanguageMap ? {
    "c.c99" = "c.99";
    "c.c99o2" = "c.99";
    "c.c99o3" = "c.99";
    "c.c11" = "c.11";
    "c.c11o2" = "c.11";
    "c.c11o3" = "c.11";
    "c.c17" = "c.17";
    "c.c17o2" = "c.17";
    "c.c17o3" = "c.17";
    "c.c23" = "c.23";
    "c.c23o2" = "c.23";
    "c.c23o3" = "c.23";
    "cc.cc11" = "cpp.11";
    "cc.cc11o2" = "cpp.11";
    "cc.cc11o3" = "cpp.11";
    "cc.cc14" = "cpp.14";
    "cc.cc14o2" = "cpp.14";
    "cc.cc14o3" = "cpp.14";
    "cc.cc17" = "cpp.17";
    "cc.cc17o2" = "cpp.17";
    "cc.cc17o3" = "cpp.17";
    "cc.cc20" = "cpp.20";
    "cc.cc20o2" = "cpp.20";
    "cc.cc20o3" = "cpp.20";
    "cc.cc23" = "cpp.23";
    "cc.cc23o2" = "cpp.23";
    "cc.cc23o3" = "cpp.23";
    "cc.cc26" = "cpp.26";
    "cc.cc26o2" = "cpp.26";
    "cc.cc26o3" = "cpp.26";
  },

  # Participant solution label shown in bundled Hull reports.
  participantSolutionName ? "hydro",

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

assert lib.assertMsg (
  builtins.isInt zstdCompressionLevel && zstdCompressionLevel >= 1 && zstdCompressionLevel <= 22
) "hydro zstdCompressionLevel must be an integer from 1 to 22";
assert lib.assertMsg (
  builtins.isInt zipCompressionLevel && zipCompressionLevel >= 0 && zipCompressionLevel <= 9
) "hydro zipCompressionLevel must be an integer from 0 to 9";
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
      staticPkgs =
        {
          "x86_64-linux" = pkgs.pkgsCross.musl64;
          "aarch64-linux" = pkgs.pkgsCross.aarch64-multiplatform-musl;
        }
        .${targetSystem} or (throw "Hydro supports only x86_64-linux and aarch64-linux");
      proot = targetHullPkgs.proot-static;
      busybox = staticPkgs.pkgsStatic.busybox;
      zstd = staticPkgs.pkgsStatic.zstd;
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
        pkgs.runCommandLocal "hull-hydro-officialData-${problem.name}-${tc.name}.tar" { } ''
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

      zstdCompressionArgs = [
        "-${toString zstdCompressionLevel}"
        "-T0"
      ]
      ++ lib.optional (zstdCompressionLevel >= 20) "--ultra";

      judgeBundleArchive = pkgs.runCommandLocal "hull-hydro-bundle-${problem.name}.tar.zst" { } ''
        set -o pipefail
        tmpdir=$(mktemp -d)
        cleanup() {
          chmod -R u+rwX "$tmpdir" 2>/dev/null || true
          rm -rf "$tmpdir"
        }
        trap cleanup EXIT

        mkdir -p "$tmpdir/bundle/solutions"
        cp ${pkgs.writeText "hull-hydro-${problem.name}.json" (builtins.toJSON metadata)} \
          "$tmpdir/bundle/problem.json"
        cp ${
          pkgs.writeText "hull-hydro-languageMap-${problem.name}.json" (
            builtins.toJSON {
              inherit hydroToHullLanguageMap;
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

        ${lib.getExe pkgs.gnutar} -C "$tmpdir" -cf - bundle \
          | ${lib.getExe pkgs.zstd} ${lib.escapeShellArgs zstdCompressionArgs} -o "$out"
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

      runtimeStoreArchive = pkgs.runCommandLocal "hull-hydro-runtimeStore-${problem.name}.tar.zst" { } ''
        set -o pipefail
        tmpdir=$(mktemp -d)
        cleanup() {
          chmod -R u+rwX "$tmpdir" 2>/dev/null || true
          rm -rf "$tmpdir"
        }
        trap cleanup EXIT

        mkdir -p "$tmpdir/nix/store"
        while IFS= read -r store_path; do
          cp -R -P --no-preserve=ownership "$store_path" "$tmpdir/nix/store/"
          chmod -R u+w "$tmpdir/nix/store/$(basename "$store_path")" 2>/dev/null || true
        done < ${targetClosure}/store-paths
        store_dir="$tmpdir/nix/store"
        while IFS= read -r -d ''' link_path; do
          target=$(readlink "$link_path")
          case "$target" in
            /*|../*|*/../*) ;;
            *) continue ;;
          esac
          case "$target" in
            /nix/store/*)
              bundled_target="$store_dir/''${target#/nix/store/}"
              ;;
            *)
              bundled_target=$(realpath -m "$(dirname "$link_path")/$target")
              case "$bundled_target" in
                "$store_dir"/*) ;;
                *) continue ;;
              esac
              ;;
          esac
          if [ -e "$bundled_target" ] || [ -L "$bundled_target" ]; then
            rm "$link_path"
            cp -R -L --no-preserve=ownership "$bundled_target" "$link_path"
            chmod -R u+w "$link_path" 2>/dev/null || true
          fi
        done < <(find "$store_dir" -type l -print0)

        ${lib.getExe pkgs.gnutar} -C "$tmpdir" -cf - nix \
          | ${lib.getExe pkgs.zstd} ${lib.escapeShellArgs zstdCompressionArgs} -o "$out"
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
                input = "/dev/null";
                output = "/dev/null";
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
          "busybox"
          "zstd"
          "hull-bundle.tar.zst"
          "hull-runtime-store.tar.zst"
        ];
        judge_extra_files = [ ];
      }
      // lib.optionalAttrs (allowedLanguages != null) { langs = allowedLanguages; };

      compileSh = pkgs.writeTextFile {
        name = "hull-hydro-compile-${problem.name}";
        executable = true;
        text = ''
          #!/bin/bash
          set -euo pipefail
          case $0 in
            */*) script_dir=''${0%/*} ;;
            *) script_dir=. ;;
          esac
          self_dir=$(CDPATH= cd -P -- "$script_dir" && pwd -P)
          bb="$self_dir/busybox"
          zstd="$self_dir/zstd"
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
          tmpdir=$("$bb" mktemp -d)
          cleanup() {
            "$bb" chmod -R u+rwX "$tmpdir" 2>/dev/null || true
            "$bb" rm -rf "$tmpdir"
          }
          trap cleanup EXIT
          "$bb" mkdir -p "$tmpdir/root"
          submission_name=''${src##*/}
          printf '%s\n' "$submission_name" > "$tmpdir/root/submission-name"
          printf '%s\n' "$HYDRO_LANG" > "$tmpdir/root/submission-language"
          "$bb" cp "$src" "$tmpdir/root/$submission_name"
          "$bb" tar -C "$tmpdir/root" -cf foo .
        '';
        checkPhase = ''
          runHook preCheck
          ${pkgs.stdenv.shellDryRun} "$target"
          runHook postCheck
        '';
      };

      executeSh = pkgs.writeTextFile {
        name = "hull-hydro-execute-${problem.name}";
        executable = true;
        text = ''
          #!/bin/bash
          set -euo pipefail
          case $0 in
            */*) script_dir=''${0%/*} ;;
            *) script_dir=. ;;
          esac
          self_dir=$(CDPATH= cd -P -- "$script_dir" && pwd -P)
          bb="$self_dir/busybox"
          zstd="$self_dir/zstd"
          bundle_path="foo"
          tmpdir=$("$bb" mktemp -d)
          cleanup() {
            "$bb" chmod -R u+rwX "$tmpdir" 2>/dev/null || true
            "$bb" rm -rf "$tmpdir"
          }
          trap cleanup EXIT
          extract_root="$tmpdir/extract"
          "$bb" mkdir -p "$extract_root"
          "$bb" tar -C "$extract_root" --no-same-owner -xf "$bundle_path"
          "$bb" mkdir -p "$extract_root/runtime-root"
          if ! "$zstd" -dc "$self_dir/hull-bundle.tar.zst" \
            | "$bb" tar -C "$extract_root" --no-same-owner -xf -; then
            printf 'failed to extract Hull judge bundle\n' >&2
            exit 1
          fi
          if ! "$zstd" -dc "$self_dir/hull-runtime-store.tar.zst" \
            | "$bb" tar -C "$extract_root/runtime-root" --no-same-owner -xf -; then
            printf 'failed to extract Hull runtime store\n' >&2
            exit 1
          fi
          stdout_report="$extract_root/stdout-report.txt"
          submission_language=$(<"$extract_root/submission-language")
          submission_name=$(<"$extract_root/submission-name")
          "$self_dir/proot" \
            -b "$extract_root/runtime-root/nix:/nix" \
            -b "$extract_root:/bundle-host" \
            -b "$extract_root/bundle:/bundle" \
            "${lib.getExe targetHullPkgs.default}" integration-judge hydro \
            --bundle-root /bundle \
            --metadata-path problem.json \
            --submission-file "/bundle-host/$submission_name" \
            --submission-language "$submission_language" \
            --language-map-path hydro-language-map.json \
            --participant-solution-name ${participantSolutionName} \
            --stdout-report-path /bundle-host/stdout-report.txt \
            --threads ${toString judgerThreads}
          "$bb" cat "$stdout_report"
        '';
        checkPhase = ''
          runHook preCheck
          ${pkgs.stdenv.shellDryRun} "$target"
          runHook postCheck
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
      ("hull-problemTargetOutput-${problem.name}-hydro" + (lib.optionalString zipped ".zip"))
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

        cp ${judgeBundleArchive} "$tmpdir/testdata/hull-bundle.tar.zst"
        cp ${runtimeStoreArchive} "$tmpdir/testdata/hull-runtime-store.tar.zst"
        cp ${proot}/bin/proot "$tmpdir/testdata/proot"
        cp ${lib.getExe busybox} "$tmpdir/testdata/busybox"
        cp ${lib.getExe zstd} "$tmpdir/testdata/zstd"
        cp ${compileSh} "$tmpdir/testdata/compile.sh"
        cp ${executeSh} "$tmpdir/testdata/execute.sh"
        chmod +x \
          "$tmpdir/testdata/compile.sh" \
          "$tmpdir/testdata/execute.sh" \
          "$tmpdir/testdata/proot" \
          "$tmpdir/testdata/busybox" \
          "$tmpdir/testdata/zstd"
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
                7zz a -tzip -mx=${toString zipCompressionLevel} -mmt=on "$out" . -x!testdata/hull-bundle.tar.zst -x!testdata/hull-runtime-store.tar.zst
                7zz a -tzip -mx=0 "$out" testdata/hull-bundle.tar.zst testdata/hull-runtime-store.tar.zst
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
