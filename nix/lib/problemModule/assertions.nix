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

{ lib, config, ... }:
{

  options = {

    assertionHelpers = lib.mkOption {
      type = lib.types.raw;
      internal = true;
      readOnly = true;
      description = "Shared helpers used to build problem assertions.";
    };

    staticAssertions = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      internal = true;
      default = [ ];
      description = ''
        Assertions that only depend on author-provided configuration and can be checked before runtime analysis.
      '';
    };

    runtimeAssertions = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      internal = true;
      default = [ ];
      description = ''
        Assertions that depend on runtime analysis data injected by the Hull CLI.
      '';
    };

    assertions = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      internal = true;
      default = [ ];
      example = [
        {
          assertion = false;
          message = "You can't enable this for that reason";
        }
      ];
      description = ''
        This option allows modules to express conditions that must
        hold for the evaluation of the system configuration to
        succeed, along with associated error messages for the user.
      '';
    };

    warnings = lib.mkOption {
      internal = true;
      default = [ ];
      type = lib.types.listOf lib.types.str;
      example = [ "The `foo' service is deprecated and will go away soon!" ];
      description = ''
        This option allows modules to show warnings to users during
        the evaluation of the system configuration.
      '';
    };

  };

  config = {
    assertionHelpers =
      let
        getTestCaseName =
          tc:
          "Test Case `${toString tc.name}` (generator: ${
            if tc.generator == null then "(manual)" else tc.generator
          }, args: ${builtins.toJSON tc.arguments})";

        getSubtaskName = index: st: "Subtask #${toString index} (traits: ${builtins.toJSON st.traits})";

        hasExactlyOne = a: b: (a != null && b == null) || (a == null && b != null);

        inputSourceDescription = item: ''
          inputFile: ${if item.inputFile == null then "null" else toString item.inputFile}
          generator: ${if item.generator == null then "null" else item.generator}
        '';

        outputSourceDescription = item: ''
          outputFile: ${if item.outputFile == null then "null" else toString item.outputFile}
          solution: ${if item.solution == null then "null" else item.solution}
        '';

        generatorNames = builtins.attrNames config.generators;
        solutionNames = builtins.attrNames config.solutions;
        subtaskCount = builtins.length config.subtasks;
        subtaskIndexRangeDescription =
          if subtaskCount == 0 then
            "This problem has no subtasks, so no subtask prediction indexes are valid."
          else
            "Valid indexes are integers from 0 to ${toString (subtaskCount - 1)}.";

        subtaskPredictionIndexIsValid =
          pred:
          let
            match = builtins.match "[0-9]+" pred.name;
          in
          match != null && (lib.toIntBase10 pred.name) < subtaskCount;
      in
      {
        inherit
          getTestCaseName
          getSubtaskName
          hasExactlyOne
          inputSourceDescription
          outputSourceDescription
          generatorNames
          solutionNames
          subtaskCount
          subtaskIndexRangeDescription
          subtaskPredictionIndexIsValid
          ;
      };

    assertions = config.staticAssertions ++ config.runtimeAssertions;
    staticAssertions =
      let
        inherit (config.assertionHelpers)
          getTestCaseName
          hasExactlyOne
          inputSourceDescription
          outputSourceDescription
          generatorNames
          solutionNames
          subtaskCount
          subtaskIndexRangeDescription
          subtaskPredictionIndexIsValid
          ;

        # Assertion: Every test case must define exactly one input source.
        testCasesWithInvalidInputSource = builtins.filter (tc: !(hasExactlyOne tc.inputFile tc.generator)) (
          builtins.attrValues config.testCases
        );
        testCaseInputSourceAssertion = {
          assertion = testCasesWithInvalidInputSource == [ ];
          message =
            let
              report = lib.concatMapStringsSep "\n" (tc: ''
                - ${getTestCaseName tc}:
                    Expected exactly one of `inputFile` or `generator`.
                    ${inputSourceDescription tc}
              '') testCasesWithInvalidInputSource;
            in
            ''
              Problem `${config.name}` has test cases with invalid input sources.
              Details:
              ${report}
            '';
        };

        # Assertion: All test case generator references must exist.
        testCasesWithUnknownGenerator = builtins.filter (
          tc: tc.generator != null && !(builtins.hasAttr tc.generator config.generators)
        ) (builtins.attrValues config.testCases);
        testCaseGeneratorReferenceAssertion = {
          assertion = testCasesWithUnknownGenerator == [ ];
          message =
            let
              report = lib.concatMapStringsSep "\n" (tc: ''
                - ${getTestCaseName tc}:
                    Unknown generator `${tc.generator}`.
                    Available generators: ${builtins.toJSON generatorNames}
              '') testCasesWithUnknownGenerator;
            in
            ''
              Problem `${config.name}` has test cases that reference missing generators.
              Details:
              ${report}
            '';
        };

        # Assertion: Every checker test must define exactly one input source.
        checkerTestsWithInvalidInputSource = lib.filterAttrs (
          name: test: !(hasExactlyOne test.inputFile test.generator)
        ) config.checker.tests;
        checkerTestInputSourceAssertion = {
          assertion = checkerTestsWithInvalidInputSource == { };
          message =
            let
              report = lib.concatMapAttrsStringSep "\n" (name: test: ''
                - Checker test `${name}`:
                    Expected exactly one of `inputFile` or `generator`.
                    ${inputSourceDescription test}
              '') checkerTestsWithInvalidInputSource;
            in
            ''
              Problem `${config.name}` has checker tests with invalid input sources.
              Details:
              ${report}
            '';
        };

        # Assertion: Every checker test must define exactly one expected-output source.
        checkerTestsWithInvalidOutputSource = lib.filterAttrs (
          name: test: !(hasExactlyOne test.outputFile test.solution)
        ) config.checker.tests;
        checkerTestOutputSourceAssertion = {
          assertion = checkerTestsWithInvalidOutputSource == { };
          message =
            let
              report = lib.concatMapAttrsStringSep "\n" (name: test: ''
                - Checker test `${name}`:
                    Expected exactly one of `outputFile` or `solution`.
                    ${outputSourceDescription test}
              '') checkerTestsWithInvalidOutputSource;
            in
            ''
              Problem `${config.name}` has checker tests with invalid output sources.
              Details:
              ${report}
            '';
        };

        # Assertion: All checker test generator and solution references must exist.
        checkerTestsWithUnknownGenerator = lib.filterAttrs (
          name: test: test.generator != null && !(builtins.hasAttr test.generator config.generators)
        ) config.checker.tests;
        checkerTestGeneratorReferenceAssertion = {
          assertion = checkerTestsWithUnknownGenerator == { };
          message =
            let
              report = lib.concatMapAttrsStringSep "\n" (name: test: ''
                - Checker test `${name}`:
                    Unknown generator `${test.generator}`.
                    Available generators: ${builtins.toJSON generatorNames}
              '') checkerTestsWithUnknownGenerator;
            in
            ''
              Problem `${config.name}` has checker tests that reference missing generators.
              Details:
              ${report}
            '';
        };

        checkerTestsWithUnknownSolution = lib.filterAttrs (
          name: test: test.solution != null && !(builtins.hasAttr test.solution config.solutions)
        ) config.checker.tests;
        checkerTestSolutionReferenceAssertion = {
          assertion = checkerTestsWithUnknownSolution == { };
          message =
            let
              report = lib.concatMapAttrsStringSep "\n" (name: test: ''
                - Checker test `${name}`:
                    Unknown solution `${test.solution}`.
                    Available solutions: ${builtins.toJSON solutionNames}
              '') checkerTestsWithUnknownSolution;
            in
            ''
              Problem `${config.name}` has checker tests that reference missing solutions.
              Details:
              ${report}
            '';
        };

        # Assertion: Every validator test must define exactly one input source.
        validatorTestsWithInvalidInputSource = lib.filterAttrs (
          name: test: !(hasExactlyOne test.inputFile test.generator)
        ) config.validator.tests;
        validatorTestInputSourceAssertion = {
          assertion = validatorTestsWithInvalidInputSource == { };
          message =
            let
              report = lib.concatMapAttrsStringSep "\n" (name: test: ''
                - Validator test `${name}`:
                    Expected exactly one of `inputFile` or `generator`.
                    ${inputSourceDescription test}
              '') validatorTestsWithInvalidInputSource;
            in
            ''
              Problem `${config.name}` has validator tests with invalid input sources.
              Details:
              ${report}
            '';
        };

        # Assertion: All validator test generator references must exist.
        validatorTestsWithUnknownGenerator = lib.filterAttrs (
          name: test: test.generator != null && !(builtins.hasAttr test.generator config.generators)
        ) config.validator.tests;
        validatorTestGeneratorReferenceAssertion = {
          assertion = validatorTestsWithUnknownGenerator == { };
          message =
            let
              report = lib.concatMapAttrsStringSep "\n" (name: test: ''
                - Validator test `${name}`:
                    Unknown generator `${test.generator}`.
                    Available generators: ${builtins.toJSON generatorNames}
              '') validatorTestsWithUnknownGenerator;
            in
            ''
              Problem `${config.name}` has validator tests that reference missing generators.
              Details:
              ${report}
            '';
        };

        # Assertion: Exactly one solution must be marked as the main correct solution.
        mainCorrectSolutions = lib.filterAttrs (
          name: solution: solution.mainCorrectSolution
        ) config.solutions;
        mainCorrectSolutionAssertion = {
          assertion = builtins.length (builtins.attrNames mainCorrectSolutions) == 1;
          message = ''
            Problem `${config.name}` must have exactly one solution with `mainCorrectSolution = true`.
            Found ${toString (builtins.length (builtins.attrNames mainCorrectSolutions))}: ${builtins.toJSON (builtins.attrNames mainCorrectSolutions)}
          '';
        };

        # Assertion: Solution subtask prediction keys must be valid subtask indexes.
        solutionsWithInvalidSubtaskPredictionIndexes = lib.mapAttrs (
          solName: sol:
          builtins.filter (pred: !(subtaskPredictionIndexIsValid pred)) (
            lib.attrsToList sol.subtaskPredictions
          )
        ) config.solutions;
        failingSubtaskPredictionIndexes = lib.filterAttrs (
          solName: invalidIndexes: invalidIndexes != [ ]
        ) solutionsWithInvalidSubtaskPredictionIndexes;
        subtaskPredictionIndexAssertion = {
          assertion = failingSubtaskPredictionIndexes == { };
          message =
            let
              report = lib.concatMapAttrsStringSep "\n" (solName: invalidIndexes: ''
                - Solution `${solName}` has invalid subtask prediction indexes: ${
                  builtins.toJSON (map (pred: pred.name) invalidIndexes)
                }
                  ${subtaskIndexRangeDescription}
              '') failingSubtaskPredictionIndexes;
            in
            ''
              Problem `${config.name}` has invalid solution subtask prediction indexes.
              Details:
              ${report}
            '';
        };

      in
      [
        testCaseInputSourceAssertion
        testCaseGeneratorReferenceAssertion
        checkerTestInputSourceAssertion
        checkerTestOutputSourceAssertion
        checkerTestGeneratorReferenceAssertion
        checkerTestSolutionReferenceAssertion
        validatorTestInputSourceAssertion
        validatorTestGeneratorReferenceAssertion
        mainCorrectSolutionAssertion
        subtaskPredictionIndexAssertion
      ];

    runtimeAssertions =
      let
        inherit (config.assertionHelpers)
          getTestCaseName
          getSubtaskName
          subtaskPredictionIndexIsValid
          ;

        # Assertion: All test cases must pass validation.
        failingValidationCases = builtins.filter (tc: tc.inputValidation.status != "valid") (
          builtins.attrValues config.testCases
        );
        validationAssertion = {
          assertion = failingValidationCases == [ ];
          message =
            let
              report = lib.concatMapStringsSep "\n" (tc: ''
                - ${getTestCaseName tc}:
                    Validation failed. Validator output: ${builtins.toJSON tc.inputValidation}
              '') failingValidationCases;
            in
            ''
              Problem `${config.name}` has test cases that failed input validation.
              Please check your generator, its arguments, and the validator logic.
              Failing cases:
              ${report}
            '';
        };

        # Assertion: All trait hints defined in `testCases.<name>.traitHints` must be declared in `problem.traits`.
        casesWithUndeclaredTraits = builtins.filter (
          tc:
          let
            definedTraits = builtins.attrNames tc.traitHints;
            undeclared = builtins.filter (
              trait: !(lib.elem trait (builtins.attrNames config.traits))
            ) definedTraits;
          in
          undeclared != [ ]
        ) (builtins.attrValues config.testCases);
        undeclaredTestCaseTraitsAssertion = {
          assertion = casesWithUndeclaredTraits == [ ];
          message =
            let
              report = lib.concatMapStringsSep "\n" (
                tc:
                let
                  definedTraits = builtins.attrNames tc.traitHints;
                  undeclared = builtins.filter (
                    trait: !(lib.elem trait (builtins.attrNames config.traits))
                  ) definedTraits;
                in
                ''
                  - ${getTestCaseName tc}:
                      The traits not declared in the problem's top-level `traits` list: ${builtins.toJSON undeclared}
                      Declared traits are: ${builtins.toJSON (builtins.attrNames config.traits)}
                ''
              ) casesWithUndeclaredTraits;
            in
            ''
              Problem `${config.name}` has test cases with undeclared traits.
              All traits defined must be listed in the problem's `traits` option.
              Details:
              ${report}
            '';
        };

        # Assertion: The user-defined `traitHints` in a test case must be a subset of the traits in validator's output.
        casesWithMismatchedTraits = builtins.filter (
          tc:
          let
            unmatchedTraits = lib.filterAttrs (
              n: v: (!builtins.hasAttr n tc.inputValidation.traits) || (tc.inputValidation.traits.${n} != v)
            ) tc.traitHints;
          in
          unmatchedTraits != { }
        ) (builtins.attrValues config.testCases);
        mismatchedTestCaseTraitsAssertion = {
          assertion = casesWithMismatchedTraits == [ ];
          message =
            let
              report = lib.concatMapStringsSep "\n" (tc: ''
                - ${getTestCaseName tc}:
                    The trait hints you defined do not match the traits returned by the validator.
                    - Defined in test case: ${builtins.toJSON tc.traitHints}
                    - Runtime traits: ${builtins.toJSON tc.inputValidation.traits}
              '') casesWithMismatchedTraits;
            in
            ''
              Problem `${config.name}` has test cases with mismatched trait hints.
              The `traitHints` attribute set in a test case should reflect the output of the validator for that case.
              Details:
              ${report}
            '';
        };

        # Assertion: All traits defined in `subtask[].traits` must be declared in `problem.traits`.
        subtasksWithUndeclaredTraits = builtins.filter (
          item:
          let
            st = item.st;
            definedTraits = builtins.attrNames st.traits;
            undeclared = builtins.filter (
              trait: !(builtins.elem trait (builtins.attrNames config.traits))
            ) definedTraits;
          in
          undeclared != [ ]
        ) (lib.imap0 (index: st: { inherit index st; }) config.subtasks);
        undeclaredSubtaskTraitsAssertion = {
          assertion = subtasksWithUndeclaredTraits == [ ];
          message =
            let
              report = lib.concatMapStringsSep "\n" (
                item:
                let
                  st = item.st;
                  definedTraits = builtins.attrNames st.traits;
                  undeclared = builtins.filter (
                    trait: !(builtins.elem trait (builtins.attrNames config.traits))
                  ) definedTraits;
                in
                ''
                  - ${getSubtaskName item.index st}:
                      The traits not declared in the problem's top-level `traits` list: ${builtins.toJSON undeclared}
                      Declared traits are: ${builtins.toJSON (builtins.attrNames config.traits)}
                ''
              ) subtasksWithUndeclaredTraits;
            in
            ''
              Problem `${config.name}` has subtasks with undeclared traits.
              All traits defined must be listed in the problem's `traits` option.
              Details:
              ${report}
            '';
        };

        # Assertion: Subtask predictions must match actual results.
        solutionsWithMismatchedPredictions = lib.mapAttrs (
          solName: sol:
          let
            predictions = sol.subtaskPredictions;
            results = sol.subtaskResults;

            predictionList = lib.attrsToList predictions;

            mismatches = builtins.filter (
              pred:
              let
                index = lib.toIntBase10 pred.name;
                predictionFunc = pred.value;
              in
              if subtaskPredictionIndexIsValid pred then
                let
                  subtaskResult = builtins.elemAt results index;
                  actualScore = subtaskResult.rawScore;
                  actualStatuses = subtaskResult.statuses;
                  predictionHolds = predictionFunc {
                    score = actualScore;
                    statuses = actualStatuses;
                  };
                in
                !predictionHolds
              else
                false
            ) predictionList;
          in
          {
            inherit (sol) subtaskResults;
            inherit mismatches;
          }
        ) config.solutions;

        failingSolutions = lib.filterAttrs (n: v: v.mismatches != [ ]) solutionsWithMismatchedPredictions;

        subtaskPredictionAssertion = {
          assertion = failingSolutions == { };
          message =
            let
              report = lib.concatMapAttrsStringSep "\n" (
                solName:
                { subtaskResults, mismatches, ... }:
                let
                  mismatchReports = lib.concatMapStringsSep "\n" (
                    pred:
                    let
                      index = lib.toIntBase10 pred.name;
                      subtask = builtins.elemAt config.subtasks index;
                      subtaskResult = builtins.elemAt subtaskResults index;
                      actualScoreStr = toString subtaskResult.rawScore;
                      actualStatusesStr = builtins.toJSON subtaskResult.statuses;
                      subtaskIdentifier = getSubtaskName index subtask;
                    in
                    ''
                      - ${subtaskIdentifier}:
                          Prediction failed with actual (raw score: ${actualScoreStr}, statuses: ${actualStatusesStr})
                    ''
                  ) mismatches;
                in
                ''
                  Solution `${solName}` has mismatched subtask predictions:
                  ${mismatchReports}
                ''
              ) failingSolutions;
            in
            ''
              Problem `${config.name}` has solutions with incorrect subtask predictions.
              Details:
              ${report}
            '';
        };

        subtasksWithoutTestCases = lib.filterAttrs (name: subtask: builtins.length subtask.testCases == 0) (
          lib.listToAttrs (
            lib.imap0 (index: subtask: {
              name = toString index;
              value = subtask;
            }) config.subtasks
          )
        );
        emptySubtaskAssertion = {
          assertion = subtasksWithoutTestCases == { };
          message =
            let
              report = lib.concatMapAttrsStringSep "\n" (index: subtask: ''
                - ${getSubtaskName (lib.toIntBase10 index) subtask}
              '') subtasksWithoutTestCases;
            in
            ''
              Problem `${config.name}` has subtasks with zero matched test cases.
              This usually means the declared subtask traits do not match any validator-derived test case traits.
              Details:
              ${report}
            '';
        };

        # Assertion: Checker tests must pass.
        failingCheckerTests = lib.filterAttrs (name: test: !test.predictionHolds) config.checker.tests;
        checkerTestsAssertion = {
          assertion = failingCheckerTests == { };
          message =
            let
              report = lib.concatMapAttrsStringSep "\n" (name: test: ''
                - Test `${name}` failed.
                  Prediction function returned false.
                  Actual checker report: ${builtins.toJSON test.result}
              '') failingCheckerTests;
            in
            ''
              Problem `${config.name}` has failing checker tests.
              Details:
              ${report}
            '';
        };

        # Assertion: Validator tests must pass.
        failingValidatorTests = lib.filterAttrs (name: test: !test.predictionHolds) config.validator.tests;
        validatorTestsAssertion = {
          assertion = failingValidatorTests == { };
          message =
            let
              report = lib.concatMapAttrsStringSep "\n" (name: test: ''
                - Test `${name}` failed.
                  Prediction function returned false.
                  Actual validator report: ${builtins.toJSON test.result}
              '') failingValidatorTests;
            in
            ''
              Problem `${config.name}` has failing validator tests.
              Details:
              ${report}
            '';
        };

      in
      [
        validationAssertion
        undeclaredTestCaseTraitsAssertion
        mismatchedTestCaseTraitsAssertion
        undeclaredSubtaskTraitsAssertion
        emptySubtaskAssertion
        subtaskPredictionAssertion
        checkerTestsAssertion
        validatorTestsAssertion
      ];
  };
}
