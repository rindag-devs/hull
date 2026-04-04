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
  pkgs,
  hull,
  hullPkgs,
  cplib,
  lib,
  ...
}:

let
  mkSpecialArgs =
    extraSpecialArgs:
    {
      inherit
        pkgs
        hull
        hullPkgs
        cplib
        ;
    }
    // extraSpecialArgs;

  runnerPath =
    runner:
    if builtins.isString runner || builtins.isPath runner then
      {
        path = toString runner;
        drvPath = null;
      }
    else
      {
        path = lib.getExe runner;
        drvPath = toString runner.drvPath;
      };

  serializeArtifact =
    artifact:
    if artifact == null then
      null
    else
      {
        path = toString artifact;
        drvPath = if artifact ? drvPath then toString artifact.drvPath else null;
      };

  withProblemModules =
    problemConfig: extraModules:
    pkgs.lib.evalModules {
      modules = [
        hull.problemModule
        problemConfig.problemAttrs
        (
          { ... }:
          {
            config.problemAttrs = problemConfig.problemAttrs;
            config.extraSpecialArgs = problemConfig.extraSpecialArgs;
          }
        )
      ]
      ++ extraModules;
      specialArgs = mkSpecialArgs problemConfig.extraSpecialArgs;
    };

  serializeProgram = program: {
    src = toString (program.src or null);
    wasm = serializeArtifact (program.wasm or null);
  };

  problemMetadata =
    problemConfig:
    {
      solutionNames ? builtins.attrNames problemConfig.solutions,
      includeTests ? true,
    }:
    let
      selectedSolutions = builtins.filter (solution: builtins.elem solution.name solutionNames) (
        builtins.attrValues problemConfig.solutions
      );
    in
    {
      name = problemConfig.name;
      tickLimit = problemConfig.tickLimit;
      memoryLimit = problemConfig.memoryLimit;
      fullScore = problemConfig.fullScore;
      checker = serializeProgram problemConfig.checker;
      validator = serializeProgram problemConfig.validator;
      generators = builtins.mapAttrs (_: serializeProgram) problemConfig.generators;
      mainCorrectSolution = problemConfig.mainCorrectSolution.name;
      judger = {
        prepareSolutionRunner = runnerPath problemConfig.judger.prepareSolution;
        generateOutputsRunner = runnerPath problemConfig.judger.generateOutputs;
        judgeRunner = runnerPath problemConfig.judger.judge;
      };
      testCases = map (tc: {
        inherit (tc)
          name
          tickLimit
          memoryLimit
          groups
          traits
          ;
        inputFile = if tc.inputFile == null then null else toString tc.inputFile;
        generator = tc.generator;
        arguments = tc.arguments;
      }) (builtins.attrValues problemConfig.testCases);
      subtasks = map (st: {
        inherit (st) fullScore scoringMethod traits;
      }) problemConfig.subtasks;
      solutions = map (solution: {
        inherit (solution)
          name
          mainCorrectSolution
          participantVisibility
          ;
        src = toString solution.src;
      }) selectedSolutions;
      checkerTests =
        if includeTests then
          map (test: {
            inherit (test)
              name
              outputName
              outputSolution
              generator
              arguments
              ;
            inputFile = if test.inputFile == null then null else toString test.inputFile;
            outputPath = if test.outputFile == null then null else toString test.outputFile;
          }) (builtins.attrValues problemConfig.checker.tests)
        else
          [ ];
      validatorTests =
        if includeTests then
          map (test: {
            inherit (test)
              name
              generator
              arguments
              ;
            inputFile = if test.inputFile == null then null else toString test.inputFile;
          }) (builtins.attrValues problemConfig.validator.tests)
        else
          [ ];
    };

  withProblemRuntimeData =
    problemConfig: runtimeData:
    withProblemModules problemConfig [
      (
        { ... }:
        {
          config.problemAttrs = problemConfig.problemAttrs;
          config.extraSpecialArgs = problemConfig.extraSpecialArgs;
          config.runtimeData = runtimeData;
        }
      )
    ];

  buildProblemTarget =
    problemConfig: runtimeData: targetName:
    let
      evaluated = withProblemRuntimeData problemConfig runtimeData;
    in
    evaluated.config.targetOutputs.${targetName};

  buildContestTarget =
    contestConfig: runtimeDataByProblem: targetName:
    let
      updatedProblems = map (
        problem: withProblemRuntimeData problem.config runtimeDataByProblem.${problem.config.name}
      ) contestConfig.problems;
      contest = contestConfig // {
        problems = updatedProblems;
      };
      assertions = builtins.concatLists (map (problem: problem.config.assertions) updatedProblems);
      warnings = builtins.concatLists (map (problem: problem.config.warnings) updatedProblems);
      checkedContest = pkgs.lib.asserts.checkAssertWarn assertions warnings contest;
    in
    checkedContest.targets.${targetName} checkedContest;

  withAdHocSolution =
    problemConfig: srcPath:
    withProblemModules problemConfig [
      (
        { ... }:
        {
          config.problemAttrs = problemConfig.problemAttrs;
          config.extraSpecialArgs = problemConfig.extraSpecialArgs;
          config.solutions.__hullAdHoc.src = /. + srcPath;
        }
      )
    ];

  adHocProblemMetadata =
    problemConfig: srcPath:
    let
      evaluated = withAdHocSolution problemConfig srcPath;
    in
    problemMetadata evaluated.config {
      solutionNames = [
        problemConfig.mainCorrectSolution.name
        "__hullAdHoc"
      ];
      includeTests = false;
    };

  contestMetadata = contest: {
    name = contest.config.name;
    problems = map (
      problem:
      let
        evaluated = if problem ? config then problem else hull.evalProblem problem { };
      in
      problemMetadata evaluated.config { }
    ) contest.config.problems;
  };
in
{
  inherit
    adHocProblemMetadata
    buildContestTarget
    buildProblemTarget
    contestMetadata
    problemMetadata
    withProblemRuntimeData
    ;
}
