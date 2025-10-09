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
}:

{
  # Name of problem target.
  problemTarget ? "default",

  # Display languages for documents.
  displayLanguages ? [ ],

  # Path of statement typst files for each problem in each display language.
  # 2-D attr set. problem name - language - path.
  # Example: { aPlusB.en = ./path/to/aPlusB/English/statement; };
  statements ? { },

  # Extra translation .typ files for statement.
  # A map from display language to file path.
  statementExtraTranslations ? { },

  # Conversion rate from Hull's ticks to milliseconds.
  # `null` means no conversion and the original tick value is used directly in the statement.
  ticksPerMs ? 1.0e7,

  # Programming languages to be displayed on the cover page of the statement.
  languages ? [
    {
      displayName = "C";
      fileNameSuffix = ".c";
      compileArguments = "gcc -lm -O3 -std=c23";
    }
    {
      displayName = "C++";
      fileNameSuffix = ".cpp";
      compileArguments = "g++ -lm -O3 -std=c++23";
    }
  ],

  # Extra typst packages for building statement.
  extraTypstPackages ? [ ],

  # Extra font paths for building statement.
  extraFontPaths ? [ ],
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
                compileArguments,
              }:
              {
                display-name = displayName;
                file-name-suffix = fileNameSuffix;
                compile-arguments = compileArguments;
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
            ++ extraTypstPackages;
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
            ++ extraFontPaths;
          };
        in
        "cp ${statement} $out/statement_${displayLanguage}.pdf"
      ) displayLanguages;
    in
    pkgs.runCommandLocal "hull-contestTargetOutput-${contest.name}-cnoiParticipant" { } ''
      mkdir $out
      ${lib.concatMapStringsSep "\n" (p: mkProblemCommand p.config) problems}
      ${statementsCommand}
    '';
}
