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
  # Defaults to cross-machine compatible Linux x86_64 for UOJ deployment.
  targetSystem ? "x86_64-linux",

  # Whether to emit a single zip archive or an unpacked directory tree.
  zipped ? true,

  # Zstandard compression level used for the bundled Nix store.
  zstdCompressionLevel ? 19,

  # ZIP compression level used for the outer archive.
  zipCompressionLevel ? 9,

  # Number of testcase judging threads used by the bundled UOJ target.
  # 0 means auto-detect based on available_parallelism().
  judgerThreads ? 0,

  # Whether the top-level score in result.txt should be rounded to an integer.
  roundTopLevelScore ? false,

  # Mapping from UOJ language names to Hull language identifiers.
  # null means the UOJ language is explicitly unsupported by the bundled UOJ target.
  uojToHullLanguageMap ? {
    "C" = "c.23";
    "C89" = "c.89";
    "C99" = "c.99";
    "C11" = "c.11";
    "C17" = "c.17";
    "C23" = "c.23";
    "C++" = "cpp.26";
    "C++98" = "cpp.98";
    "C++03" = "cpp.03";
    "C++11" = "cpp.11";
    "C++14" = "cpp.14";
    "C++17" = "cpp.17";
    "C++20" = "cpp.20";
    "C++23" = "cpp.23";
    "C++26" = "cpp.26";
  },

  # A map of name to file path. These files will be placed in `download/`.
  extraDownloadFiles ? { },
}:

assert lib.assertMsg (
  builtins.isInt zstdCompressionLevel && zstdCompressionLevel >= 1 && zstdCompressionLevel <= 22
) "uoj zstdCompressionLevel must be an integer from 1 to 22";
assert lib.assertMsg (
  builtins.isInt zipCompressionLevel && zipCompressionLevel >= 0 && zipCompressionLevel <= 9
) "uoj zipCompressionLevel must be an integer from 0 to 9";
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
      samples,
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
        .${targetSystem} or (throw "UOJ supports only x86_64-linux and aarch64-linux");
      uojSupervisor = staticPkgs.rustPlatform.buildRustPackage {
        pname = "hull-uoj-supervisor";
        version = "0.1.0";
        src = lib.sourceByRegex ./supervisor [
          "Cargo.toml"
          "Cargo.lock"
          "src(/.*)?"
        ];
        cargoLock.lockFile = ./supervisor/Cargo.lock;
        doCheck = false;
        strictDeps = true;
        RUSTFLAGS = "-C target-feature=+crt-static -C relocation-model=static -C link-arg=-no-pie";
        meta = {
          license = lib.licenses.lgpl3Plus;
          mainProgram = "hull-uoj-supervisor";
        };
      };
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
        pkgs.runCommandLocal "hull-uoj-officialData-${problem.name}-${tc.name}.tar" { } ''
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

      judgeBundleData = pkgs.runCommandLocal "hull-uoj-data-${problem.name}" { } ''
        mkdir -p $out/data $out/solutions
        cp ${pkgs.writeText "hull-uoj-${problem.name}.json" (builtins.toJSON metadata)} \
          $out/problem.json
        cp ${
          pkgs.writeText "hull-uoj-languageConfig-${problem.name}.json" (
            builtins.toJSON {
              uojToHullLanguageMap = uojToHullLanguageMap;
            }
          )
        } $out/uoj-language-config.json
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
      judgeRunner = targetPkgs.writeShellScriptBin "hull-uoj-integration-judge-runner-${problem.name}" ''
        bundle_root="$1"
        submission_file="$2"
        submission_language="$3"
        uoj_work_path="$4"
        uoj_result_path="$5"
        uoj_data_path="$6"
        exec ${lib.getExe targetHullPkgs.default} integration-judge uoj \
          --bundle-root "$bundle_root" \
          --metadata-path "problem.json" \
          --submission-file "$submission_file" \
          --submission-language "$submission_language" \
          --uoj-work-path "$uoj_work_path" \
          --uoj-result-path "$uoj_result_path" \
          --uoj-data-path "$uoj_data_path" \
          ${lib.optionalString roundTopLevelScore "--round-top-level-score"} \
          --threads ${toString judgerThreads}
      '';

      judgeRunnerStorePath = builtins.unsafeDiscardStringContext (toString judgeRunner);
      judgeRunnerRelative = "/nix/store/${baseNameOf judgeRunnerStorePath}/bin/hull-uoj-integration-judge-runner-${problem.name}";

      targetClosureRoots = [
        judgeRunner
        targetHullPkgs.default
        targetHullPkgs.wasm32-wasi-wasip1.clang
        nixUserChroot
        problem.checker.wasm
        problem.validator.wasm
        targetJudger.prepareSolution
        targetJudger.generateOutputs
        targetJudger.judge
      ];
      targetClosure = pkgs.closureInfo {
        rootPaths = targetClosureRoots;
      };
      runtimeId = builtins.hashString "sha256" (
        builtins.toJSON {
          closure = builtins.unsafeDiscardStringContext (toString targetClosure);
          nixUserChroot = nixUserChrootRelative;
          runner = judgeRunnerRelative;
        }
      );
      zstdCompressionArgs = [
        "-${toString zstdCompressionLevel}"
        "-T0"
      ]
      ++ lib.optional (zstdCompressionLevel >= 20) "--ultra";

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

      samplesCommand = lib.concatStringsSep "\n" (
        map (tc: ''
          cp ${tc.data.input} $tmpdir/download/sample_${tc.name}.in
          outputs=()
          for output_path in ${tc.data.outputs}/*; do
            [ -f "$output_path" ] || continue
            outputs+=("$output_path")
          done
          if [ "''${#outputs[@]}" -eq 1 ]; then
            cp "''${outputs[0]}" "$tmpdir/download/sample_${tc.name}.out"
          else
            for output_path in "''${outputs[@]}"; do
              output_name=$(basename "$output_path")
              cp "$output_path" "$tmpdir/download/sample_${tc.name}_''${output_name}.out"
            done
          fi
        '') samples
      );

    in
    pkgs.runCommandLocal
      ("hull-problemTargetOutput-${problem.name}-uoj" + lib.optionalString zipped ".zip")
      {
        nativeBuildInputs = [ pkgs._7zz ];
      }
      ''
        set -o pipefail
        tmpdir=$(mktemp -d)
        cleanup() {
          rm -rf "$tmpdir"
        }
        trap cleanup EXIT

        mkdir -p "$tmpdir/download"
        mkdir -p "$tmpdir/hull-bundle/nix/store"

        while IFS= read -r store_path; do
          cp -R -P --no-preserve=ownership "$store_path" "$tmpdir/hull-bundle/nix/store/"
          chmod -R u+w "$tmpdir/hull-bundle/nix/store/$(basename "$store_path")" 2>/dev/null || true
        done < ${targetClosure}/store-paths
        store_dir="$tmpdir/hull-bundle/nix/store"
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

        cp -R -P --no-preserve=ownership ${judgeBundleData}/. "$tmpdir/hull-bundle/"
        chmod -R u+rwX "$tmpdir/hull-bundle"
        tar -C "$tmpdir/hull-bundle/nix" -cf - store \
          | ${lib.getExe pkgs.zstd} ${lib.escapeShellArgs zstdCompressionArgs} -o "$tmpdir/hull-bundle/nix-store.tar.zst"
        rm -rf "$tmpdir/hull-bundle/nix/store"
        rmdir "$tmpdir/hull-bundle/nix"
        cp ${lib.getExe uojSupervisor} "$tmpdir/judger"
        cp ${lib.getExe staticPkgs.pkgsStatic.busybox} "$tmpdir/busybox"
        cp ${lib.getExe staticPkgs.pkgsStatic.zstd} "$tmpdir/zstd"
        cp ${pkgs.writeText "hull-uoj-supervisor.conf" ''
          nix_user_chroot_store_suffix=${lib.removePrefix "/nix/store" nixUserChrootRelative}
          runner=${judgeRunnerRelative}
          runtime_id=${runtimeId}
        ''} "$tmpdir/hull-bundle/supervisor.conf"
        cp ${pkgs.writeText "problem.conf" problemConf} "$tmpdir/problem.conf"
        cp ${./judger.mk} "$tmpdir/Makefile"
        cp ${./prepare.c} "$tmpdir/hull-uoj-prepare.c"
        cp ${./README.txt} "$tmpdir/README.txt"

        ${lib.concatMapAttrsStringSep "\n" (
          docName: doc:
          lib.optionalString doc.participantVisibility "cp ${doc.path} $tmpdir/download/document_${docName}"
        ) documents}

        ${samplesCommand}

        ${hull.problemTarget.utils.participantProgramsCommand {
          inherit problem;
          dest = "$tmpdir/download";
          flattened = true;
        }}

        ${mkCopyCommands "$tmpdir/download" extraDownloadFiles}

        ${
          if zipped then
            ''
              (
                cd "$tmpdir"
                7zz a -tzip -mx=${toString zipCompressionLevel} -mmt=on "$out" . -x!hull-bundle/nix-store.tar.zst
                7zz a -tzip -mx=0 "$out" hull-bundle/nix-store.tar.zst
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
