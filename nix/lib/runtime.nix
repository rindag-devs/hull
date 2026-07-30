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
        drv_path = null;
      }
    else
      {
        path = lib.getExe runner;
        drv_path = toString runner.drvPath;
      };

  serializeArtifact =
    artifact:
    if artifact == null then
      null
    else
      {
        path = toString artifact;
        drv_path = if artifact ? drvPath then toString artifact.drvPath else null;
      };

  serializeRuntimeFile =
    file:
    if file == null then
      null
    else
      toString (
        if builtins.isPath file then
          builtins.path {
            path = file;
            name = baseNameOf file;
          }
        else
          file
      );

  writeMetadata =
    name: metadata: anchors:
    let
      # Keep runner and WASM artifacts on the existing realization path. Only
      # the lightweight runtime-file anchors belong to the metadata closure.
      json = builtins.unsafeDiscardStringContext (builtins.toJSON metadata);
      anchorContext = builtins.getContext (builtins.toJSON anchors);
    in
    pkgs.writeText name (builtins.appendContext json anchorContext);

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

  checkStaticProblemConfig =
    problemConfig:
    pkgs.lib.asserts.checkAssertWarn problemConfig.staticAssertions problemConfig.warnings
      problemConfig;

  problemMetadata =
    problemConfig:
    {
      solutionNames ? builtins.attrNames problemConfig.solutions,
      includeTests ? true,
    }:
    let
      checkedProblemConfig = checkStaticProblemConfig problemConfig;
      selectedSolutions = builtins.filter (solution: builtins.elem solution.name solutionNames) (
        builtins.attrValues checkedProblemConfig.solutions
      );
      runtimeFiles = builtins.filter (file: file != null) (
        map (solution: serializeRuntimeFile solution.src) selectedSolutions
        ++ map (testCase: serializeRuntimeFile testCase.inputFile) (
          builtins.attrValues checkedProblemConfig.testCases
        )
        ++ lib.optionals includeTests (
          map (test: serializeRuntimeFile test.inputFile) (
            builtins.attrValues checkedProblemConfig.checker.tests
          )
          ++ map (test: serializeRuntimeFile test.outputFile) (
            builtins.attrValues checkedProblemConfig.checker.tests
          )
          ++ map (test: serializeRuntimeFile test.inputFile) (
            builtins.attrValues checkedProblemConfig.validator.tests
          )
        )
      );
      runtimeFilesAnchor = pkgs.writeText "hull-problem-${checkedProblemConfig.name}-runtime-files.json" (
        builtins.toJSON runtimeFiles
      );
    in
    {
      name = checkedProblemConfig.name;
      tick_limit = checkedProblemConfig.tickLimit;
      memory_limit = checkedProblemConfig.memoryLimit;
      file_size_limit = checkedProblemConfig.fileSizeLimit;
      full_score = checkedProblemConfig.fullScore;
      checker = serializeProgram checkedProblemConfig.checker;
      validator = serializeProgram checkedProblemConfig.validator;
      generators = builtins.mapAttrs (_: serializeProgram) checkedProblemConfig.generators;
      main_correct_solution = checkedProblemConfig.mainCorrectSolution.name;
      judger = {
        prepare_solution_runner = runnerPath checkedProblemConfig.judger.prepareSolution;
        generate_outputs_runner = runnerPath checkedProblemConfig.judger.generateOutputs;
        judge_runner = runnerPath checkedProblemConfig.judger.judge;
      };
      test_cases = map (tc: {
        inherit (tc) name groups;
        tick_limit = tc.tickLimit;
        memory_limit = tc.memoryLimit;
        trait_hints = tc.traitHints;
        input_file = serializeRuntimeFile tc.inputFile;
        generator = tc.generator;
        arguments = tc.arguments;
      }) (builtins.attrValues checkedProblemConfig.testCases);
      subtasks = map (st: {
        full_score = st.fullScore;
        scoring_method = st.scoringMethod;
        inherit (st) traits;
      }) checkedProblemConfig.subtasks;
      solutions = map (solution: {
        inherit (solution) name;
        main_correct_solution = solution.mainCorrectSolution;
        participant_visibility = solution.participantVisibility;
        src = serializeRuntimeFile solution.src;
      }) selectedSolutions;
      runtime_files_anchor = toString runtimeFilesAnchor;
      checker_tests =
        if includeTests then
          map (test: {
            inherit (test) name generator arguments;
            output_name = test.outputName;
            output_solution = test.outputSolution;
            input_file = serializeRuntimeFile test.inputFile;
            output_path = serializeRuntimeFile test.outputFile;
          }) (builtins.attrValues checkedProblemConfig.checker.tests)
        else
          [ ];
      validator_tests =
        if includeTests then
          map (test: {
            inherit (test)
              name
              generator
              arguments
              ;
            input_file = serializeRuntimeFile test.inputFile;
          }) (builtins.attrValues checkedProblemConfig.validator.tests)
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
        (checkStaticProblemConfig problemConfig).mainCorrectSolution.name
        "__hullAdHoc"
      ];
      includeTests = false;
    };

  problemMetadataFile =
    problemConfig: options:
    let
      metadata = problemMetadata problemConfig options;
    in
    writeMetadata "hull-problem-${problemConfig.name}-runtime-metadata.json" metadata [
      metadata.runtime_files_anchor
    ];

  adHocProblemMetadataFile =
    problemConfig: srcPath:
    let
      metadata = adHocProblemMetadata problemConfig srcPath;
    in
    writeMetadata "hull-problem-${problemConfig.name}-ad-hoc-runtime-metadata.json" metadata [
      metadata.runtime_files_anchor
    ];

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

  contestMetadataFile =
    contest:
    let
      metadata = contestMetadata contest;
    in
    writeMetadata "hull-contest-${contest.config.name}-runtime-metadata.json" metadata (
      map (problem: problem.runtime_files_anchor) metadata.problems
    );
in
{
  inherit
    adHocProblemMetadata
    adHocProblemMetadataFile
    buildContestTarget
    buildProblemTarget
    contestMetadata
    contestMetadataFile
    problemMetadata
    problemMetadataFile
    withProblemRuntimeData
    ;
}
