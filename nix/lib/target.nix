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
        ...
      }:
      let
        dataCommand = pkgs.lib.concatLines (
          map (tc: ''
            mkdir -p $out/data/${tc.name}
            cp ${tc.data.input} $out/data/${tc.name}/input
            cp ${tc.data.output} $out/data/${tc.name}/output
            echo ${pkgs.lib.escapeShellArg (builtins.toJSON tc.inputValidation)} > $out/data/${tc.name}/input-validation.json
          '') (builtins.attrValues testCases)
        );

        subtaskCommand = pkgs.lib.concatLines (
          pkgs.lib.imap0 (
            index: st:
            let
              linkSubtaskDataCommand = pkgs.lib.concatLines (
                map (
                  tc: "ln -sr $out/data/${tc.name} $out/subtask/${builtins.toString index}/${tc.name}"
                ) st.testCases
              );
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
            testCaseResults,
            src,
            language,
            ...
          }:
          let
            copyTestCaseResultsCommand = pkgs.lib.concatMapAttrsStringSep "\n" (
              tcName:
              { run, check }:
              let
                dirPrefix = "$out/solution/${solName}/test-case-result/${tcName}";
              in
              ''
                mkdir -p ${dirPrefix}
                cp ${run.stdout} ${dirPrefix}/stdout
                cp ${run.stderr} ${dirPrefix}/stderr
                echo ${pkgs.lib.escapeShellArg (builtins.toJSON run.report)} > ${dirPrefix}/run-report.json
                echo ${pkgs.lib.escapeShellArg (builtins.toJSON check)} > ${dirPrefix}/check-report.json
              ''
            ) testCaseResults;
          in
          ''
            mkdir -p $out/solution/${solName}
            cp ${src} $out/solution/${solName}/src.${hull.language.toFileExtension language}
            ${copyTestCaseResultsCommand}
          ''
        ) solutions;
      in
      pkgs.runCommandLocal "hull-target-output-${name}-default" { } ''
        ${dataCommand}

        ${subtaskCommand}

        mkdir -p $out/solution
        ${solutionsCommand}

        mkdir -p $out/generator
        ${generatorsCommand}

        ${checkerCommand}
      '';
  };
}
