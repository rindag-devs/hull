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
        solutions,
        generators,
        checker,
        ...
      }:
      let
        copyDataCommand = pkgs.lib.concatLines (
          pkgs.lib.imap0 (
            index: testCase:
            "cp ${testCase.data.input} $out/data/${builtins.toString index}.in"
            + "\n"
            + "cp ${testCase.data.output} $out/data/${builtins.toString index}.ans"
            + "\n"
            + "cp ${builtins.toFile "data.json" (builtins.toJSON testCase.inputValidation)} $out/data/${builtins.toString index}.json"
          ) testCases
        );

        copyProgramCommand =
          path: programName: program:
          "cp ${program.src} $out/${path}/${builtins.toString programName}.${hull.language.toFileExtension program.language}";

        copyProgramsCommand =
          dirName: programs:
          pkgs.lib.concatMapAttrsStringSep "\n" (
            programName: program: copyProgramCommand dirName programName program
          ) programs;

        copySolutionsCommand = copyProgramsCommand "solution" solutions;
        copyGeneratorsCommand = copyProgramsCommand "generator" generators;
        copyCheckerCommand = copyProgramCommand "" "checker" checker;
      in
      pkgs.runCommandLocal "hull-default-out-${name}" { } ''
        mkdir -p $out/data
        ${copyDataCommand}

        mkdir -p $out/solution
        ${copySolutionsCommand}

        mkdir -p $out/generator
        ${copyGeneratorsCommand}

        ${copyCheckerCommand}
      '';
  };
}
