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

=== File And Directory Naming

The case of a file or directory name is decided by its content type, in priority order:

- *Code files* follow their language's identifier convention: C/C++ and Rust use `snake_case` (`std_optimized.17.cpp`), Nix uses `camelCase` (`batch.nix`, `problemModule/`), and other languages follow their ecosystem.
- *Typst documents* and files mainly consumed by Typst use `kebab-case` (`document/statement/en.typ`).
- *Subprojects* carry their language's rule over the whole subtree; nested subprojects are judged independently.
- *Generic files and directories* (data, config, samples) use `kebab-case` (`data/hand-1.in`, `compile_flags.txt`).
- *Machine-interface suffixes* are exempt from case judgment: the dotted `.<version>.<ext>` tail (`std.17.cpp`) is the language-detection interface and is not a word separator.
- *Conventional names* are exempt: `README.md`, `LICENSE`, `flake.nix`, `Cargo.toml`, `.clang-format`.
- Code identifiers are not file names: the Nix `name` field stays `camelCase` even though the directory it names uses the content-type rule.

== Directory Structure

Recommended layout:

A typical problem directory looks like this:

```text
.
├── authoring-include/
│   └── problem.23.hpp
├── data/
│   └── 1.in
├── document/
│   └── statement/
│       ├── en.typ
│       └── ...
├── generator/
│   └── rand.23.cpp
├── solution-include/
│   └── add.h
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

- `authoring-include/`: Shared header files, like `problem.23.hpp`, used by authoring programs (checker, validator, interactor). Solutions cannot see this directory.
- `data/`: Manually created test case input files.
- `document/`: Source files for generating problem statements (e.g., Typst files).
- `generator/`: Source code for test data generators.
- `solution-include/`: Header files that solutions must include, such as a grader header. Register the directory in `solutionIncludes` in `problem.nix`.
- `solution/`: Source code for all solutions (correct, incorrect, suboptimal).
- `checker.23.cpp`: The checker program.
- `validator.23.cpp`: The validator program.
- `problem.nix`: The central declarative configuration for the problem.
- `flake.nix`: The Nix flake definition for the project.

=== Sharing Problem Definitions

Keep definitions used by both the checker and validator in the matching `authoring-include/problem.*.hpp`, and add `./authoring-include` to `authoringIncludes` in `problem.nix`. This shared header should be the single source of truth for input models, parsing rules, constraint constants, and other reusable problem structures. Interactive problems should use the same approach for definitions shared by the interactor and validator. A grader header that solutions must include goes to `solution-include/` and is registered in `solutionIncludes` instead, keeping solutions restricted to exactly the interface they need.

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

Keep component tests short and focused on plausible defects, such as a missing bound, trailing token, malformed construction, floating-point tolerance boundary, or protocol violation. Do not enumerate the input domain or add tests that only assert constants or implementation shape.

=== Predicting Solution Behavior

`subtaskPredictions` checks expected solution behavior.

For a brute-force solution that is expected to be too slow for larger subtasks, you can write a prediction that accepts either "accepted" (for small cases) or "time_limit_exceeded".

The complete testcase status vocabulary is `accepted`, `wrong_answer`, `partially_correct`, `runtime_error`, `time_limit_exceeded`, `memory_limit_exceeded`, `file_error`, and `internal_error`.

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

== Reproducible Test Data

Make generator output depend only on its complete command-line argument sequence. Avoid wall-clock seeds, `rand`, implementation-dependent iteration order, and other runtime state. Running the same generator with the same arguments should produce byte-for-byte identical output.

Give independently variable input dimensions separate generator modes, such as size, value distribution, parity, density, or structural shape. Combine relevant modes systematically and add directed boundary cases; random sampling alone is not coverage.

Use generated inputs by default. Fixed input files remain appropriate for small samples or exceptional constructions that are clearer as literal data. Both `sample` and `sampleLarge` are sample groups: `sample` cases are embedded in generated statements, while `sampleLarge` cases are distributed without being expanded inline.

== Subtasks And Test Coverage

Define subtask membership through precise affirmative traits emitted by the validator. Trait hints are checked author assertions, not a replacement for validator-derived traits. Keep statement constraints, validator conditions, generator arguments, testcase traits, and solution assumptions consistent.

A single-subtask ICPC-style problem often needs roughly 20 to 100 testcases. A problem with many partial-scoring subtasks may need hundreds or thousands. These are guidelines rather than quotas; use the smallest set that strongly covers algorithm branches, boundaries, structural families, and plausible unintended approaches.

Problem scores conventionally total `1.0`. Allocate partial scores primarily by difficulty, with modest additional weight when a subtask gives useful insight toward the intended solution. For a problem without partial scoring, prefer one subtask containing every testcase.

== Participant Visibility

Keep solutions, generators, validators, checkers, and interactors private unless participants require a specific distributed interface. Statements and required grader headers or libraries are exceptions. Check the generated option reference before setting visibility because component kinds use different option types.

=== Editor Configuration

The `.editorconfig` file helps maintain consistent coding styles (like indentation and line endings) across various editors and IDEs.

== Version Control

Keep build artifacts and temporary files out of version control.
