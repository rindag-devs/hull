#import "/templates/page.typ": page

#show: page.with(
  title: "Basic Workflow",
  summary: "Learn the main Hull CLI commands for building packages, judging solutions, and running stress tests.",
)

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
hull judge solution/std.23.cpp
```

Use `--json` to print JSON instead of a table.

== Compiling a Solution

`hull compile` compiles one source file to a WebAssembly executable using the selected problem's languages and includes.

```bash
hull compile solution/std.23.cpp
```

The default output is `std.wasm` in the working directory. Use `-p` to select a problem, `-l` to select a language instead of detecting it from the source suffix, and `-o` to select another output path:

```bash
hull compile -p example -l cpp.23 -o solution.wasm solution/std.23.cpp
```

Use `-o -` to write the raw WASM module to standard output:

```bash
hull compile -o - solution/std.23.cpp > solution.wasm
```

== Running a Solution

`hull run` uses the same problem, language, and source compilation options as `hull compile`, then executes the resulting WASM module in Hull's runner.

```bash
hull run -p example -l cpp.23 solution/std.23.cpp
```

Arguments after the source path are passed to the program. Prefix arguments that start with `-` with a `--` separator. Use `--tick-limit`, `--memory-limit`, and `--show-status` to control and inspect execution.

The program can access only its working directory. It defaults to the directory where Hull was started; use `--cwd` to select another host directory:

```bash
hull run --cwd sandbox solution/std.23.cpp
```

== Stress Testing

`hull stress` runs a generator repeatedly, builds temporary test cases, compares one or more solutions against the standard solution, and stops on the first non-accepted result.

For example, imagine you have a potentially buggy solution `wa` and a generator named `rand`. You can stress test it with the following command:

```bash
hull stress --generator rand wa -- some parameters passed --to=generator
```

Use `-j` to control parallel cases per round. Use `-r` to set a finite number of rounds.
