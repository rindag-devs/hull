#import "../book.typ": book-page

#show: book-page.with(title: "Basic Workflow")

= Basic Workflow

This chapter covers the main Hull commands.

Run all commands inside `nix develop`.

== The `hull` Command-Line Interface (CLI)

Show the command list with:

```bash
hull --help
```

== Building the Problem Package

`hull build` analyzes one problem, realizes runtime artifacts, and packages one problem target.

Run:

```bash
hull build
```

The default output link is `result`. Use `-p` to select a problem, `-t` to select a target, `-o` to select the output link, and `-j` to set runtime analysis parallelism. Arguments after `--` are passed to the final `nix build`.

The output layout depends on the selected target. A common target usually contains:

- `data/`: Contains all test case inputs and the corresponding standard answer files.
- `solution/`: Contains detailed judging results for every defined solution.
- `generator/`: Contains the source code for your generators.
- `checker.*.cpp`, `validator.*.cpp`: Source code for your core programs.
- `overview.pdf`: An automatically generated technical overview of the problem.
- `document/`: Contains any generated documents, such as the problem statement PDF.

== Judging a Solution

`hull judge` treats one source file as an extra solution and runs full problem analysis for it.

Example:

```bash
hull judge solution/std.20.cpp
```

Use `--json` to print JSON instead of a table.

== Stress Testing

`hull stress` runs a generator repeatedly, builds temporary test cases, compares one or more solutions against the standard solution, and stops on the first non-accepted result.

For example, imagine you have a potentially buggy solution `wa` and a generator named `rand`. You can stress test it with the following command:

```bash
hull stress --generator rand wa -- some parameters passed --to=generator
```

Use `-j` to control parallel cases per round. Use `-r` to set a finite number of rounds.
