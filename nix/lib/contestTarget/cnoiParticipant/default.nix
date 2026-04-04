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
  # Display languages for documents.
  displayLanguages ? [ ],

  # Path of statement typst files for each problem in each display language.
  # 2-D attr set. problem name - language - path.
  # Example: { aPlusB.en = ./path/to/aPlusB/English/statement.typ; };
  statements ? { },

  # Extra translation .typ files for statement.
  # A map from display language to file path.
  statementExtraTranslations ? { },

  # Conversion rate from Hull's ticks to milliseconds.
  # `null` means no conversion and the original tick value is used directly in the statement.
  ticksPerMs ? null,

  # Programming languages to be displayed on the cover page of the statement.
  languages ? [
    {
      displayName = "C";
      fileNameSuffix = ".c";
      displayCompileArguments = "gcc -O3 -std=c23";
      hullLanguage = "c.23.s64m";
    }
    {
      displayName = "C++";
      fileNameSuffix = ".cpp";
      displayCompileArguments = "g++ -O3 -std=c++23";
      hullLanguage = "cpp.23.s64m";
    }
  ],

  # Extra typst packages for building statement.
  statementExtraTypstPackages ? [ ],

  # Extra font paths for building statement.
  statementExtraFontPaths ? [ ],

  # Whether to include selfeval in the participant package.
  enableSelfEval ? false,

  # Whether the target output should be a .tar.xz archive instead of a directory.
  archive ? false,
}:

{
  _type = "hullContestTarget";
  __functor =
    self:
    {
      problems,
      ...
    }@contest:
    let
      nixUserChroot = hullPkgs.nix-user-chroot;

      mkSampleCommand =
        { samples, ... }@problem:
        lib.concatMapStringsSep "\n" (
          tc:
          let
            dataPathPrefix = "$out/${problem.name}/data/${tc.name}";
          in
          ''
            mkdir -p ${dataPathPrefix}
            cp ${tc.data.input} ${dataPathPrefix}/input
            cp -r ${tc.data.outputs} ${dataPathPrefix}/outputs
          ''
        ) samples;

      mkProgramCopyCommand =
        pathPrefix: name: program:
        if program.participantVisibility == "src" then
          let
            ext = hull.language.toFileExtension program.language;
            dest = "${pathPrefix}/${name}.${ext}";
          in
          "cp ${program.src} ${dest}"
        else if program.participantVisibility == "wasm" then
          let
            dest = "${pathPrefix}/${name}.wasm";
          in
          "cp ${program.wasm} ${dest}"
        else
          ""; # No-op for "no" visibility

      mkProgramsCopyCommand =
        pathPrefix: programs:
        let
          hasVisibleProgram = builtins.any ({ participantVisibility, ... }: participantVisibility != "no") (
            builtins.attrValues programs
          );
        in
        lib.optionalString hasVisibleProgram ''
          mkdir -p ${pathPrefix}
          ${lib.concatMapAttrsStringSep "\n" (mkProgramCopyCommand pathPrefix) programs}
        '';

      mkSolutionsCopyCommand =
        pathPrefix: solutions:
        let
          hasVisibleSolution = builtins.any ({ participantVisibility, ... }: participantVisibility) (
            builtins.attrValues solutions
          );
        in
        lib.optionalString hasVisibleSolution ''
          mkdir -p ${pathPrefix}
          ${lib.concatMapAttrsStringSep "\n" (
            name: sol: lib.optionalString sol.participantVisibility "cp ${sol.src} ${pathPrefix}/${name}"
          ) solutions}
        '';

      mkDocumentsCopyCommand =
        pathPrefix: documents:
        let
          hasVisibleSolution = builtins.any ({ participantVisibility, ... }: participantVisibility) (
            builtins.attrValues documents
          );
        in
        lib.optionalString hasVisibleSolution ''
          mkdir -p ${pathPrefix}
          ${lib.concatMapAttrsStringSep "\n" (
            name: doc: lib.optionalString doc.participantVisibility "cp ${doc.path} ${pathPrefix}/${name}"
          ) documents}
        '';

      mkProblemCommand =
        {
          documents,
          checker,
          validator,
          solutions,
          generators,
          ...
        }@problem:
        let
          pathPrefix = "$out/${problem.name}";
        in
        ''
          mkdir -p ${pathPrefix}

          ${mkSampleCommand problem}

          # Copy visible documents
          ${mkDocumentsCopyCommand "${pathPrefix}/document" documents}

          # Copy visible programs
          ${mkProgramCopyCommand "${pathPrefix}" "checker" checker}
          ${mkProgramCopyCommand "${pathPrefix}" "validator" validator}
          ${mkProgramsCopyCommand "${pathPrefix}/generator" generators}
          ${mkSolutionsCopyCommand "${pathPrefix}/solution" solutions}
        '';

      selfEvalManifest = {
        name = contest.name;
        languages = map (
          {
            displayName,
            fileNameSuffix,
            hullLanguage,
            ...
          }:
          {
            displayName = displayName;
            fileNameSuffix = fileNameSuffix;
            hullLanguage = hullLanguage;
          }
        ) languages;
        problems = map (problem: {
          name = problem.config.name;
          fullScore = problem.config.fullScore;
          metadataPath = "problems/${problem.config.name}.json";
        }) problems;
      };

      selfEvalData = pkgs.runCommandLocal "hull-cnoiParticipantSelfEvalData-${contest.name}" { } ''
        mkdir -p $out
        cp ${builtins.toFile "contest.json" (builtins.toJSON selfEvalManifest)} $out/contest.json
        mkdir -p $out/problems
        ${lib.concatMapStringsSep "\n" (
          problem:
          let
            metadata = {
              name = problem.config.name;
              tickLimit = problem.config.tickLimit;
              memoryLimit = problem.config.memoryLimit;
              fullScore = problem.config.fullScore;
              judger = {
                prepareSolutionRunner = {
                  path = builtins.unsafeDiscardStringContext (lib.getExe problem.config.judger.prepareSolution);
                  drvPath = null;
                };
                generateOutputsRunner = null;
                judgeRunner = {
                  path = builtins.unsafeDiscardStringContext (lib.getExe problem.config.judger.judge);
                  drvPath = null;
                };
              };
              testCases = map (tc: {
                name = tc.name;
                tickLimit = tc.tickLimit;
                memoryLimit = tc.memoryLimit;
                groups = tc.groups;
                traits = tc.traits;
              }) problem.config.samples;
              subtasks = map (st: {
                fullScore = st.fullScore;
                scoringMethod = st.scoringMethod;
                traits = st.traits;
              }) problem.config.subtasks;
            };
            metadataFile = pkgs.writeText "hull-selfeval-${problem.config.name}.json" (
              builtins.toJSON metadata
            );
          in
          "cp ${metadataFile} $out/problems/${problem.config.name}.json"
        ) problems}
      '';

      selfEvalRunner = pkgs.writeShellScriptBin "selfeval-run" ''
        package_root="$1"
        shift
        exec ${lib.getExe hullPkgs.default} self-eval --bundle-root ${selfEvalData} --package-root "$package_root" "$@"
      '';

      selfEvalTargets = [
        selfEvalRunner
        hullPkgs.default
        hullPkgs.wasm32-wasi-wasip1.clang
        selfEvalData
        nixUserChroot
      ]
      ++ lib.concatMap (problem: [
        problem.config.judger.prepareSolution
        problem.config.judger.judge
      ]) problems;

      selfEvalClosure = pkgs.closureInfo { rootPaths = selfEvalTargets; };

      nixUserChrootStorePath = builtins.unsafeDiscardStringContext (toString nixUserChroot);
      nixUserChrootRelative = "/nix/store/${baseNameOf nixUserChrootStorePath}/bin/nix-user-chroot";

      selfEvalLauncher = pkgs.writeText "hull-cnoiParticipant-selfeval-${contest.name}" ''
        #!/usr/bin/env bash
        set -eu
        self_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
        bundle_dir="$self_dir/.selfeval-bundle"
        self_dest=$(printf '%s' "$self_dir" | sed 's|^/||')
        participant_map_arg=""
        if [ "$#" -ge 1 ] && [ -e "$1" ]; then
          participant_root=$(realpath "$1")
          participant_dest=$(printf '%s' "$participant_root" | sed 's|^/||')
          participant_map_arg="-m $participant_root:$participant_dest"
          shift
          set -- "$participant_root" "$@"
        fi
        cd "$bundle_dir"
        if [ -n "$participant_map_arg" ]; then
          exec ".${nixUserChrootRelative}" \
            -m "$self_dir:$self_dest" \
            -m "$participant_root:$participant_dest" \
            -n ./nix \
            -- ${selfEvalRunner}/bin/selfeval-run "$self_dir" "$@"
        else
          exec ".${nixUserChrootRelative}" \
            -m "$self_dir:$self_dest" \
            -n ./nix \
            -- ${selfEvalRunner}/bin/selfeval-run "$self_dir" "$@"
        fi
      '';

      selfEvalCommand = lib.optionalString enableSelfEval ''
        mkdir -p $out/.selfeval-bundle/nix/store
        while IFS= read -r store_path; do
          cp -a --no-preserve=ownership "$store_path" $out/.selfeval-bundle/nix/store/
        done < ${selfEvalClosure}/store-paths
        cp ${selfEvalLauncher} $out/selfeval
        chmod +x $out/selfeval
      '';

      outputDir =
        pkgs.runCommandLocal "hull-contestTargetOutput-${contest.name}-cnoiParticipant-dir" { }
          ''
            mkdir $out
            ${lib.concatMapStringsSep "\n" (p: mkProblemCommand p.config) problems}
            ${statementsCommand}
            ${selfEvalCommand}
          '';

      statementsCommand = lib.concatMapStringsSep "\n" (
        let
          statementSrc = pkgs.runCommandLocal "hull-cnoiParticipantStatementSrc-${contest.name}" { } ''
            mkdir $out
            cp ${./statement/main.typ} $out/main.typ
            cp -r ${./statement/translation} $out/translation
            ${lib.concatMapAttrsStringSep "\n" (
              displayLanguage: path: "cp -f ${path} $out/translation/${displayLanguage}.typ"
            ) statementExtraTranslations}
            ${lib.concatMapAttrsStringSep "\n" (
              problemName:
              lib.concatMapAttrsStringSep "\n" (
                displayLanguage: path: "install -Dm644 ${path} $out/problem/${problemName}/${displayLanguage}.typ"
              )
            ) statements}
          '';
          renderJSONContent = {
            ticks-per-ms = ticksPerMs;
            languages = map (
              {
                displayName,
                fileNameSuffix,
                displayCompileArguments,
                hullLanguage,
              }:
              {
                display-name = displayName;
                file-name-suffix = fileNameSuffix;
                display-compile-arguments = displayCompileArguments;
                hull-language = hullLanguage;
              }
            ) languages;
          };
          renderJSONName = "hull-cnoiParticipantStatementRenderJSON-${contest.name}.json";
          renderJSONPath = builtins.toFile renderJSONName (builtins.toJSON renderJSONContent);
        in
        displayLanguage:
        let
          statement = hull.document.mkContestTypstDocument contest {
            src = statementSrc;
            virtualPaths = [
              {
                dest = renderJSONName;
                src = renderJSONPath;
              }
            ];
            inputs = {
              language = displayLanguage;
              render-json-path = renderJSONName;
            };
            typstPackages = [
              {
                name = "titleize";
                version = "0.1.1";
                hash = "sha256-Z0okd0uGhUDpdLXWpS+GvKVk1LSs15CE7l0l7kZqWLo=";
              }
              {
                name = "diagraph";
                version = "0.3.6";
                hash = "sha256-U/KxwlNyCIFHyMJKkjeQ4NDCYZhqNgM+oxJZ8Lov3nA=";
              }
            ]
            ++ statementExtraTypstPackages;
            fontPaths = [
              "${pkgs.source-han-sans}/share/fonts/opentype/source-han-sans"
              "${pkgs.source-han-serif}/share/fonts/opentype/source-han-serif"
              (pkgs.ibm-plex.override {
                families = [
                  "sans"
                  "serif"
                  "mono"
                  "math"
                ];
              })
            ]
            ++ statementExtraFontPaths;
          };
        in
        "cp ${statement} $out/statement.${displayLanguage}.pdf"
      ) displayLanguages;
    in
    if archive then
      pkgs.runCommandLocal "hull-contestTargetOutput-${contest.name}-cnoiParticipant.tar.xz" { } ''
        tmp_archive_dir=$(mktemp -d)
        trap 'rm -rf "$tmp_archive_dir"' EXIT
        staged_dir="$tmp_archive_dir/${contest.name}"
        mkdir -p "$staged_dir"
        cp -r --no-preserve=ownership ${outputDir}/. "$staged_dir/"
        chmod -R u+rwX,go+rX "$staged_dir"
        rm -rf "$out"
        tar -C "$tmp_archive_dir" -cJf "$out" "${contest.name}"
      ''
    else
      outputDir;
}
