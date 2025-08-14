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

        getSubtaskName = st: "Subtask (traits: ${st.traits})";

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
          st:
          let
            definedTraits = builtins.attrNames st.traits;
            undeclared = builtins.filter (trait: !(lib.elem trait config.traits)) definedTraits;
          in
          undeclared != [ ]
        ) config.subtasks;
        undeclaredSubtaskTraitsAssertion = {
          assertion = subtasksWithUndeclaredTraits == [ ];
          message =
            let
              report = lib.concatStringsSep "\n" (
                lib.map (
                  st:
                  let
                    definedTraits = builtins.attrNames st.traits;
                    undeclared = builtins.filter (trait: !(lib.elem trait config.traits)) definedTraits;
                  in
                  ''
                    - ${getSubtaskName st}:
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

      in
      [
        validationAssertion
        undeclaredTestCaseTraitsAssertion
        mismatchedTestCaseTraitsAssertion
        undeclaredSubtaskTraitsAssertion
      ];
  };
}
