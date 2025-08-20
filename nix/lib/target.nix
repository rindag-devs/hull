# This file defines the final build targets for a problem.

{ pkgs, hull }:

{
  default = {
    _type = "hullTarget";
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
        dataCommand = pkgs.lib.concatMapStringsSep "\n" (tc: ''
          mkdir -p $out/data/${tc.name}
          cp ${tc.data.input} $out/data/${tc.name}/input
          cp ${tc.data.output} $out/data/${tc.name}/output
          echo ${pkgs.lib.escapeShellArg (builtins.toJSON tc.inputValidation)} > $out/data/${tc.name}/input-validation.json
        '') (builtins.attrValues testCases);

        subtaskCommand = pkgs.lib.concatLines (
          pkgs.lib.imap0 (
            index: st:
            let
              linkSubtaskDataCommand = pkgs.lib.concatMapStringsSep "\n" (
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
          pkgs.lib.concatMapAttrsStringSep "\n" (
            programName: program: copyProgramCommand dirName programName program
          ) programs;

        generatorsCommand = programsCommand "generator" generators;
        checkerCommand = copyProgramCommand "" "checker" checker;

        solutionsCommand = pkgs.lib.concatMapAttrsStringSep "\n" (
          solName:
          {
            src,
            testCaseResults,
            subtaskResults,
            score,
            ...
          }:
          let
            testCaseResultsCommand = pkgs.lib.concatMapAttrsStringSep "\n" (
              tcName:
              { run, check, ... }@result:
              let
                dirPrefix = "$out/solution/${solName}/test-case-result/${tcName}";
                reportJSON = builtins.toJSON (
                  removeAttrs result [
                    "run"
                    "check"
                  ]
                );
                runJSON = builtins.toJSON (
                  removeAttrs result.run [
                    "stdout"
                    "stderr"
                  ]
                );
                checkJSONCommand =
                  if result.check != null then
                    "echo ${pkgs.lib.escapeShellArg (builtins.toJSON result.check)} > ${dirPrefix}/check.json"
                  else
                    "";
              in
              ''
                mkdir -p ${dirPrefix}
                cp ${run.stdout} ${dirPrefix}/stdout
                cp ${run.stderr} ${dirPrefix}/stderr
                echo ${pkgs.lib.escapeShellArg reportJSON} > ${dirPrefix}/result.json
                echo ${pkgs.lib.escapeShellArg runJSON} > ${dirPrefix}/run.json
                ${checkJSONCommand}
              ''
            ) testCaseResults;
            subtaskResultsCommand = pkgs.lib.concatLines (
              pkgs.lib.imap0 (
                index:
                { testCases, ... }@result:
                let
                  dirPrefix = "$out/solution/${solName}/subtask-result/${builtins.toString index}";
                  reportJSON = builtins.toJSON (builtins.removeAttrs result [ "testCases" ]);
                  linkTestCasesCommand = pkgs.lib.concatMapAttrsStringSep "\n" (
                    tcName: tc: "ln -sr $out/solution/${solName}/test-case-result/${tcName} ${dirPrefix}/${tcName}"
                  ) testCases;
                in
                ''
                  mkdir -p ${dirPrefix}
                  echo ${pkgs.lib.escapeShellArg reportJSON} > ${dirPrefix}/result.json
                  ${linkTestCasesCommand}
                ''
              ) subtaskResults
            );
          in
          ''
            mkdir -p $out/solution/${solName}
            cp ${src} $out/solution/${solName}/src
            ${testCaseResultsCommand}
            ${subtaskResultsCommand}
            echo ${builtins.toString score} > $out/solution/${solName}/score.txt
          ''
        ) solutions;
        documentsCommand = pkgs.lib.concatMapAttrsStringSep "\n" (documentName: document: ''
          cp ${document.path} $out/documents/${documentName}
        '') documents;
        overviewCommand = "cp ${hull.overview.mkOverview problem} $out/overview.pdf";
      in
      pkgs.runCommandLocal "hull-target-output-${name}-default" { } ''
        ${dataCommand}

        ${subtaskCommand}

        mkdir -p $out/solution
        ${solutionsCommand}

        mkdir -p $out/generator
        ${generatorsCommand}

        ${checkerCommand}

        mkdir -p $out/documents
        ${documentsCommand}

        ${overviewCommand}
      '';
  };
}
