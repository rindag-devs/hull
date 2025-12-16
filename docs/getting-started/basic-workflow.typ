#import "../book.typ": book-page

#show: book-page.with(title: "Basic Workflow")

= Basic Workflow

After initializing your project and entering the development environment with `nix develop`, you can begin working with your problem. This chapter introduces the core commands of the `hull` command-line interface (CLI), which form the foundation of the problem development lifecycle.

*Prerequisite:* All commands described below must be executed from within the Nix development shell, which you enter by running `nix develop` in your project's root directory.

== The `hull` Command-Line Interface (CLI)

The `hull` CLI is your primary tool for interacting with the Hull framework. It provides a suite of commands for building, testing, and analyzing your competitive programming problems. You can explore all available commands and their options by running:

```bash
hull --help
```

Let's explore the most essential commands in a typical workflow.

== Building the Problem Package

The `hull build` command is a comprehensive validation and packaging step. It serves as a sanity check for your entire problem configuration, ensuring that everything is consistent and correct before you proceed.

*What it does:*
- *Evaluates `problem.nix`*: It parses your problem definition, including all test cases, subtasks, solutions, and programs.
- *Runs Automated Checks*: It automatically runs tests on your validator and checker, and critically, it verifies that the performance of each solution on each subtask matches your `subtaskPredictions`. This catches inconsistencies early.
- *Builds the Default Target*: It compiles all necessary components and packages them into a final, structured output according to the `default` target defined in `problem.nix`.

To build your problem, simply run:

```bash
hull build
```

Upon successful completion, Hull creates a symbolic link named `result` in your project directory. This link points to the build output in the Nix store. The contents of this directory depend on the target definition (e.g., `problemTarget.common`), but it typically contains a structured layout of your entire problem:

- `data/`: Contains all test case inputs and the corresponding standard answer files.
- `solution/`: Contains detailed judging results for every defined solution.
- `generator/`: Contains the source code for your generators.
- `checker.*.cpp`, `validator.*.cpp`: Source code for your core programs.
- `overview.pdf`: An automatically generated technical overview of the problem.
- `document/`: Contains any generated documents, such as the problem statement PDF.

== Judging a Solution

To test a single solution file against the problem's test cases, use the `hull judge` command. This is the most frequent command you will use during development to verify the correctness of your solutions.

*What it does:*

- *Compiles the Solution*: It compiles the specified source file to a WebAssembly module.
- *Executes Against Test Cases*: It runs the compiled module against every test case defined in `problem.nix`, enforcing the specified `tickLimit` and `memoryLimit`.
- *Checks the Output*: It uses the problem's `checker` to compare the solution's output against the standard answer for each test case.
- *Generates a Report*: It prints a detailed, human-readable report of the results.

For example, to judge the standard correct solution provided in the template:

```bash
hull judge solution/std.20.cpp
```

The output will be a comprehensive report summarizing the performance across subtasks and detailing the results for each test case.

== Stress Testing

Stress testing (also known as fuzz testing or randomized testing) is a powerful technique for finding bugs and edge cases in solutions. The `hull stress` command automates this process by comparing one or more solutions against a trusted "standard" solution on a large number of randomly generated test cases.

*What it requires:*

- A *generator* program to create random inputs.
- A *standard solution* (marked with `mainCorrectSolution = true` or specified with `--std`) to produce the correct answer for each random input.
- One or more *solutions to test*.

*What it does:*

1. In a loop, it repeatedly calls the specified generator with a random seed to create a new test case.
2. It runs the standard solution to get the correct answer.
3. It runs the solution-under-test on the same input.
4. It uses the problem's checker to compare their outputs.
5. If the outputs differ, it has found a "hack" (a failing test case) and reports it. Otherwise, it continues to the next round.

For example, imagine you have a potentially buggy solution `wa` and a generator named `rand`. You can stress test it with the following command:

```bash
hull stress --generator rand wa -- some parameters passed --to=generator
```

If a failing test case is found, the process stops and prints a report, including the generator arguments that produced the failing case. This makes it easy to reproduce the failure and add it to your `problem.nix` for regression testing.
