#import "/templates/page.typ": page

#show: page.with(
  title: "Best Practices & Conventions",
  summary: "Follow recommended Hull naming conventions, project layout, component tests, and reproducible data practices.",
)

= Best Practices & Conventions

Use consistent names and a predictable layout.

== Naming Conventions

Recommended naming:

- *Problem Name, Test Cases, Generators, Solutions*: Use `camelCase` for the machine-readable identifier. This name is often used in directory paths, so avoid spaces or special characters.
  - Good: `aPlusB`, `newYearGreeting`.
  - Bad: `A + B Problem`, `new_year_greeting`.
- *Traits*: Use concise, descriptive `snake_case` names that state the property precisely.
  - For numeric constraints, prefer `variable_comparison_value`, such as `n_le_1000`, `a_ge_100`, or `a_mod_2_eq_0`.
  - For categorical or structural properties, use an affirmative `is_property` or `variable_is_property` name, such as `is_tree` or `n_is_odd`. Other concise and descriptive names, such as `all_positive`, are also appropriate.
  - Avoid vague names such as `n_is_small`, `trait1`, and `subtask2_property`.
  - Avoid negation in trait names. For example, use `is_tree = false` instead of `is_not_tree = true`.

== Directory Structure

Recommended layout:

A typical problem directory looks like this:

```text
.
├── data/
│   └── 1.in
├── document/
│   └── statement/
│       ├── en.typ
│       └── ...
├── generator/
│   └── rand.23.cpp
├── include/
│   └── problem.23.hpp
├── solution/
│   ├── bf.23.cpp
│   └── std.23.cpp
├── .clang-format
├── .clangd
├── .editorconfig
├── .gitignore
├── checker.23.cpp
├── flake.nix
├── problem.nix
└── validator.23.cpp
```

- `data/`: Manually created test case input files.
- `document/`: Source files for generating problem statements (e.g., Typst files).
- `generator/`: Source code for test data generators.
- `include/`: Shared header files, like `problem.23.hpp`, used by other components.
- `solution/`: Source code for all solutions (correct, incorrect, suboptimal).
- `checker.23.cpp`: The checker program.
- `validator.23.cpp`: The validator program.
- `problem.nix`: The central declarative configuration for the problem.
- `flake.nix`: The Nix flake definition for the project.

=== Sharing Problem Definitions

Keep definitions used by both the checker and validator in the matching `include/problem.*.hpp`, and add `./include` to `includes` in `problem.nix`. This shared header should be the single source of truth for input models, parsing rules, constraint constants, and other reusable problem structures. Interactive problems should use the same approach for definitions shared by the interactor and validator.

Keep `checker.*.cpp`, `validator.*.cpp`, and `interactor.*.cpp` as thin entry points that include the shared header and register the relevant component. Do not duplicate input structures, bounds, or parsing logic between these programs: duplicated definitions can drift and cause the checker or interactor to interpret input differently from the validator.

== Testing Core Components

Your `validator` and `checker` are critical pieces of software that can contain bugs. Hull provides a built-in mechanism to write tests for them directly within `problem.nix`, ensuring they behave as expected.

=== Testing the Validator and Checker

You can add a `tests` attribute to your `validator` and `checker` definitions. Each test case specifies an input and a `prediction` function that verifies the program's output.

```nix
# In problem.nix
{
  # ...
  validator = {
    src = ./validator.23.cpp;
    tests = {
      # Test case with a valid input
      valid = {
        inputFile = builtins.toFile "invalid.in" "1 2\n";
        prediction = { status, traits, ... }:
          status == "valid" && traits.a_positive;
      };
      # Test case with an invalid input
      invalid = {
        inputFile = builtins.toFile "invalid.in" "1001 1002\n";
        prediction = { status, ... }: status == "invalid";
      };
    };
  };

  checker = {
    src = ./checker.23.cpp;
    tests = {
      # Test an accepted case
      ac = {
        inputFile = builtins.toFile "ac.in" "1 2\n";
        outputFile = builtins.toFile "ac.out" "3\n";
        prediction = { status, ... }: status == "accepted";
      };
    };
  };
  # ...
}
```

When you run `hull build`, these tests are executed automatically. If any prediction fails, the build will stop, alerting you to a potential issue with your validator or checker.

=== Predicting Solution Behavior

`subtaskPredictions` checks expected solution behavior.

For a brute-force solution that is expected to be too slow for larger subtasks, you can write a prediction that accepts either "accepted" (for small cases) or "time_limit_exceeded".

```nix
# In problem.nix
{
  # ...
  solutions = {
    std = {
      src = ./solution/std.23.cpp;
      mainCorrectSolution = true;
      subtaskPredictions."0" = { score, ... }: score == 1.0; # Expect AC
    };

    bruteForce = {
      src = ./solution/bf.23.cpp;
      subtaskPredictions."0" = { statuses, ... }:
        builtins.all (s: s == "accepted" || s == "time_limit_exceeded") statuses;
    };
  };
  # ...
}
```

== Code Style

Maintaining a consistent code style is essential for collaboration and long-term maintenance. The Hull template provides configuration files for common formatting and linting tools.

=== Nix Formatting

The project flake includes a formatter for Nix code using `nixfmt-tree`. You can format all Nix files in your project by running:

```bash
nix fmt
```

=== C/C++ Development Environment

The template provides configuration files for a consistent C/C++ development experience.

- *.clang-format*: Defines the code style for `clang-format`.
- *.clangd*: Configures the `clangd` language server, enabling features like auto-completion and diagnostics. It automatically sets the correct C++ standard based on file extensions (e.g., `.23.cpp` for C++ 23).

=== Editor Configuration

The `.editorconfig` file helps maintain consistent coding styles (like indentation and line endings) across various editors and IDEs.

== Version Control

Keep build artifacts and temporary files out of version control.
