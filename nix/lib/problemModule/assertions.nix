{ lib, config, ... }:
{

  options = {

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
    assertions =
      let
        getTestCaseName =
          tc:
          "Test Case `${toString tc.name}` (generator: ${tc.generator}, args: ${builtins.toJSON tc.arguments})";

        getSubtaskName = index: st: "Subtask #${toString index} (traits: ${builtins.toJSON st.traits})";

        # Assertion: All test cases must pass validation.
        failingValidationCases = builtins.filter (tc: tc.inputValidation.status != "valid") (
          builtins.attrValues config.testCases
        );
        validationAssertion = {
          assertion = failingValidationCases == [ ];
          message =
            let
              report = lib.concatStringsSep "\n" (
                lib.map (tc: ''
                  - ${getTestCaseName tc}:
                      Validation failed. Validator output: ${builtins.toJSON tc.inputValidation}
                '') failingValidationCases
              );
            in
            ''
              Problem `${config.name}` has test cases that failed input validation.
              Please check your generator, its arguments, and the validator logic.
              Failing cases:
              ${report}
            '';
        };

        # Assertion: All traits defined in `testCases.<name>.traits` must be declared in `problem.traits`.
        casesWithUndeclaredTraits = builtins.filter (
          tc:
          let
            definedTraits = builtins.attrNames tc.traits;
            undeclared = builtins.filter (trait: !(lib.elem trait config.traits)) definedTraits;
          in
          undeclared != [ ]
        ) (builtins.attrValues config.testCases);
        undeclaredTestCaseTraitsAssertion = {
          assertion = casesWithUndeclaredTraits == [ ];
          message =
            let
              report = lib.concatStringsSep "\n" (
                lib.map (
                  tc:
                  let
                    definedTraits = builtins.attrNames tc.traits;
                    undeclared = builtins.filter (trait: !(lib.elem trait config.traits)) definedTraits;
                  in
                  ''
                    - ${getTestCaseName tc}:
                        The traits not declared in the problem's top-level `traits` list: ${builtins.toJSON undeclared}
                        Declared traits are: ${builtins.toJSON config.traits}
                  ''
                ) casesWithUndeclaredTraits
              );
            in
            ''
              Problem `${config.name}` has test cases with undeclared traits.
              All traits defined must be listed in the problem's `traits` option.
              Details:
              ${report}
            '';
        };

        # Assertion: The user-defined `traits` in a test case must be a subset of the traits in validator's output.
        casesWithMismatchedTraits = builtins.filter (
          tc:
          let
            unmatchedTraits = lib.filterAttrs (
              n: v: (!builtins.hasAttr n tc.inputValidation.traits) || (tc.inputValidation.traits.${n} != v)
            ) tc.traits;
          in
          unmatchedTraits != { }
        ) (builtins.attrValues config.testCases);
        mismatchedTestCaseTraitsAssertion = {
          assertion = casesWithMismatchedTraits == [ ];
          message =
            let
              report = lib.concatStringsSep "\n" (
                lib.map (tc: ''
                  - ${getTestCaseName tc}:
                      The traits you defined do not match the traits returned by the validator.
                      - Defined in test case: ${builtins.toJSON tc.traits}
                      - Returned by validator: ${builtins.toJSON tc.inputValidation.traits}
                '') casesWithMismatchedTraits
              );
            in
            ''
              Problem `${config.name}` has test cases with mismatched trait definitions.
              The `traits` attribute set in a test case should reflect the output of the validator for that case.
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
            undeclared = builtins.filter (trait: !(builtins.elem trait config.traits)) definedTraits;
          in
          undeclared != [ ]
        ) (lib.imap0 (index: st: { inherit index st; }) config.subtasks);
        undeclaredSubtaskTraitsAssertion = {
          assertion = subtasksWithUndeclaredTraits == [ ];
          message =
            let
              report = lib.concatStringsSep "\n" (
                map (
                  item:
                  let
                    st = item.st;
                    definedTraits = builtins.attrNames st.traits;
                    undeclared = builtins.filter (trait: !(builtins.elem trait config.traits)) definedTraits;
                  in
                  ''
                    - ${getSubtaskName item.index st}:
                        The traits not declared in the problem's top-level `traits` list: ${builtins.toJSON undeclared}
                        Declared traits are: ${builtins.toJSON config.traits}
                  ''
                ) subtasksWithUndeclaredTraits
              );
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
              if index < 0 || index >= (builtins.length results) then
                true # Prediction for non-existent subtask is a mismatch.
              else
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
              report = lib.concatStringsSep "\n\n" (
                lib.mapAttrsToList (
                  solName:
                  { subtaskResults, mismatches, ... }:
                  let
                    mismatchReports = lib.concatMapStringsSep "\n" (
                      pred:
                      let
                        index = lib.toIntBase10 pred.name;
                        subtask =
                          if index >= 0 && index < (builtins.length config.subtasks) then
                            builtins.elemAt config.subtasks index
                          else
                            null;
                        subtaskResult =
                          if index >= 0 && index < (builtins.length subtaskResults) then
                            builtins.elemAt subtaskResults index
                          else
                            null;
                        actualScore =
                          if subtaskResult != null then toString subtaskResult.rawScore else "N/A (non-existent subtask)";
                        actualStatuses = if subtaskResult != null then toString subtaskResult.statuses else [ ];
                        subtaskIdentifier =
                          if subtask != null then
                            getSubtaskName index subtask
                          else
                            "Subtask #${toString index} (non-existent)";
                      in
                      ''
                        - ${subtaskIdentifier}:
                            Prediction failed with actual (raw score: ${actualScore}, statuses: ${builtins.toJSON actualStatuses})
                      ''
                    ) mismatches;
                  in
                  ''
                    Solution `${solName}` has mismatched subtask predictions:
                    ${mismatchReports}
                  ''
                ) failingSolutions
              );
            in
            ''
              Problem `${config.name}` has solutions with incorrect subtask predictions.
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
        subtaskPredictionAssertion
      ];
  };
}
