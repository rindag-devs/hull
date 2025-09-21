#import "../../book.typ": book-page

#show: book-page.with(title: "Best Practices & Conventions")

= Best Practices & Conventions

This chapter outlines a set of recommended practices and conventions for developing problems with Hull. Adhering to these guidelines will help maintain consistency, readability, and robustness in your projects, making them easier to manage, debug, and collaborate on.

== Naming Conventions

Consistent naming is crucial for a clean and understandable problem definition. While Hull does not enforce a strict naming scheme, we strongly recommend adopting a consistent style for different types of identifiers within your `problem.nix` and file structure.

- *Problem Name, Test Cases, Generators, Solutions*: Use `camelCase` for the machine-readable identifier. This name is often used in directory paths, so avoid spaces or special characters.
  - Good: `aPlusB`, `newYearGreeting`.
  - Bad: `A + B Problem`, `new_year_greeting`.
- *Traits*: Use descriptive `snake_case` to clearly state the property the trait represents.
  - Good: `n_is_small`, `all_positive`, `is_tree`.
  - Bad: `trait1`, `subtask2_property`.

The key is to choose a style and apply it consistently throughout your project.

== Directory Structure

The official Hull template provides a standard directory structure that organizes all components of a problem logically. It is highly recommended to follow this structure to maintain clarity and consistency.

A typical problem directory looks like this:

```plain
.
├── data/
│   └── 1.in
├── document/
│   └── statement/
│       ├── main.typ
│       └── ...
├── generator/
│   └── rand.20.cpp
├── include/
│   └── problem.h
├── solution/
│   ├── bf.20.cpp
│   └── std.20.cpp
├── .clang-format
├── .clangd
├── .editorconfig
├── .gitignore
├── checker.20.cpp
├── flake.nix
├── problem.nix
└── validator.20.cpp
```

- `data/`: Manually created test case input files.
- `document/`: Source files for generating problem statements (e.g., Typst files).
- `generator/`: Source code for test data generators.
- `include/`: Shared header files, like `problem.h`, used by other components.
- `solution/`: Source code for all solutions (correct, incorrect, suboptimal).
- `checker.20.cpp`: The checker program.
- `validator.20.cpp`: The validator program.
- `problem.nix`: The central declarative configuration for the problem.
- `flake.nix`: The Nix flake definition for the project.

== Testing Core Components

Your `validator` and `checker` are critical pieces of software that can contain bugs. Hull provides a built-in mechanism to write tests for them directly within `problem.nix`, ensuring they behave as expected.

=== Testing the Validator and Checker

You can add a `tests` attribute to your `validator` and `checker` definitions. Each test case specifies an input and a `prediction` function that verifies the program's output.

```nix
# In problem.nix
{
  # ...
  validator = {
    src = ./validator.20.cpp;
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
    src = ./checker.20.cpp;
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

The `subtaskPredictions` attribute for each solution is another powerful testing tool. It verifies that your solutions perform exactly as you expect. This is especially useful for ensuring that time-limit-exceeded (TLE) solutions actually time out and wrong-answer (WA) solutions fail on the correct subtasks.

For a brute-force solution that is expected to be too slow for larger subtasks, you can write a prediction that accepts either "accepted" (for small cases) or "time_limit_exceeded".

```nix
# In problem.nix
{
  # ...
  solutions = {
    std = {
      src = ./solution/std.20.cpp;
      mainCorrectSolution = true;
      subtaskPredictions."0" = { score, ... }: score == 1.0; # Expect AC
    };

    bruteForce = {
      src = ./solution/bf.20.cpp;
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
- *.clangd*: Configures the `clangd` language server, enabling features like auto-completion and diagnostics. It automatically sets the correct C++ standard based on file extensions (e.g., `.20.cpp` for C++ 20).

=== Editor Configuration

The `.editorconfig` file helps maintain consistent coding styles (like indentation and line endings) across various editors and IDEs.

== Version Control

A well-configured `.gitignore` file is crucial to keep your repository clean by excluding build artifacts and temporary files. The template provides a comprehensive default and ensures that temporary Nix store links, compiled binaries, and other generated files are not committed to your version control system.
