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
}:

{
  _type = "hullProblemTarget";
  __functor =
    self:
    {
      name,
      testCases,
      subtasks,
      solutions,
      generators,
      checker,
      documents,
      ...
    }@problem:
    let
      dataCommand = lib.concatMapStringsSep "\n" (
        tc:
        let
          dirPrefix = "$out/data/${lib.escapeShellArg tc.name}";
        in
        ''
          mkdir -p ${dirPrefix}
          cp ${tc.data.input} ${dirPrefix}/input
          cp -r ${tc.data.outputs} ${dirPrefix}/outputs
          echo ${lib.escapeShellArg (builtins.toJSON tc.inputValidation)} > $out/data/${tc.name}/input-validation.json
        ''
      ) (builtins.attrValues testCases);

      subtaskCommand = lib.concatLines (
        lib.imap0 (
          index: st:
          let
            linkSubtaskDataCommand = lib.concatMapStringsSep "\n" (
              tc: "ln -sr $out/data/${tc.name} $out/subtask/${builtins.toString index}/${tc.name}"
            ) st.testCases;
          in
          ''
            mkdir -p $out/subtask/${builtins.toString index}
            ${linkSubtaskDataCommand}
          ''
        ) subtasks
      );

      copyProgramCommand =
        path: programName: program:
        "cp ${program.src} $out/${path}/${builtins.toString programName}.${hull.language.toFileExtension program.language}";

      programsCommand =
        dirName: programs:
        lib.concatMapAttrsStringSep "\n" (
          programName: program: copyProgramCommand dirName programName program
        ) programs;

      generatorsCommand = programsCommand "generator" generators;
      checkerCommand = copyProgramCommand "" "checker" checker;

      solutionsCommand = lib.concatMapAttrsStringSep "\n" (
        solName:
        {
          src,
          testCaseResults,
          subtaskResults,
          score,
          ...
        }:
        let
          testCaseResultsCommand = lib.concatMapAttrsStringSep "\n" (
            tcName: result:
            let
              dirPrefix = "$out/solution/${solName}/test-case-result/${tcName}";
              resultJSON = builtins.toJSON (builtins.removeAttrs result [ "output" ]);
            in
            ''
              mkdir -p ${dirPrefix}
              echo ${lib.escapeShellArg resultJSON} > ${dirPrefix}/result.json
              cp -r ${result.outputs} ${dirPrefix}/outputs
            ''
          ) testCaseResults;
          subtaskResultsCommand = lib.concatLines (
            lib.imap0 (
              index:
              { testCases, ... }@result:
              let
                dirPrefix = "$out/solution/${solName}/subtask-result/${builtins.toString index}";
                reportJSON = builtins.toJSON (builtins.removeAttrs result [ "testCases" ]);
                linkTestCasesCommand = lib.concatMapAttrsStringSep "\n" (
                  tcName: tc: "ln -sr $out/solution/${solName}/test-case-result/${tcName} ${dirPrefix}/${tcName}"
                ) testCases;
              in
              ''
                mkdir -p ${dirPrefix}
                echo ${lib.escapeShellArg reportJSON} > ${dirPrefix}/result.json
                ${linkTestCasesCommand}
              ''
            ) subtaskResults
          );
        in
        ''
          mkdir -p $out/solution/${solName}
          cp -r ${src} $out/solution/${solName}/src
          ${testCaseResultsCommand}
          ${subtaskResultsCommand}
          echo ${builtins.toString score} > $out/solution/${solName}/score.txt
        ''
      ) solutions;
      documentsCommand = lib.concatMapAttrsStringSep "\n" (documentName: document: ''
        cp ${document.path} $out/document/${documentName}
      '') documents;
      overviewCommand = "cp ${hull.overview.mkOverview problem} $out/overview.pdf";
    in
    pkgs.runCommandLocal "hull-problemTargetOutput-${name}-common" { } ''
      ${dataCommand}

      ${subtaskCommand}

      mkdir -p $out/solution
      ${solutionsCommand}

      mkdir -p $out/generator
      ${generatorsCommand}

      ${checkerCommand}

      mkdir -p $out/document
      ${documentsCommand}

      ${overviewCommand}
    '';
}
