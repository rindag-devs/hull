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
        # Helper to generate a descriptive name for a test case for use in error messages.
        getTestCaseName =
          tc:
          "Test Case `${toString tc.name}` (generator: ${tc.generator}, args: ${builtins.toJSON tc.arguments})";

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

        # Assertion: All traits returned by the validator must be declared in `problem.traits`.
        casesWithUndeclaredTraits = builtins.filter (
          tc:
          let
            validatedTraits = builtins.attrNames tc.inputValidation.traits;
            undeclared = builtins.filter (trait: !(lib.elem trait config.traits)) validatedTraits;
          in
          undeclared != [ ]
        ) (builtins.attrValues config.testCases);
        undeclaredTraitsAssertion = {
          assertion = casesWithUndeclaredTraits == [ ];
          message =
            let
              report = lib.concatStringsSep "\n" (
                lib.map (
                  tc:
                  let
                    validatedTraits = builtins.attrNames tc.inputValidation.traits;
                    undeclared = builtins.filter (trait: !(lib.elem trait config.traits)) validatedTraits;
                  in
                  ''
                    - ${getTestCaseName tc}:
                        The validator returned traits not declared in the problem's top-level `traits` list: ${builtins.toJSON undeclared}
                        Declared traits are: ${builtins.toJSON config.traits}
                  ''
                ) casesWithUndeclaredTraits
              );
            in
            ''
              Problem `${config.name}` has test cases with undeclared traits.
              All traits returned by the validator must be listed in the problem's `traits` option.
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
        mismatchedTraitsAssertion = {
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

      in
      [
        validationAssertion
        undeclaredTraitsAssertion
        mismatchedTraitsAssertion
      ];
  };
}
