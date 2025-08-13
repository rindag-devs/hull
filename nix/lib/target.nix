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
          map (tc: ''
            mkdir -p $out/data/${tc.name}
            cp ${tc.data.input} $out/data/${tc.name}/input.txt
            cp ${tc.data.output} $out/data/${tc.name}/output.txt
            cp ${builtins.toFile "data.json" (builtins.toJSON tc.inputValidation)} $out/data/${tc.name}/input-validation.json
          '') (builtins.attrValues testCases)
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
        ${copyDataCommand}

        mkdir -p $out/solution
        ${copySolutionsCommand}

        mkdir -p $out/generator
        ${copyGeneratorsCommand}

        ${copyCheckerCommand}
      '';
  };
}
