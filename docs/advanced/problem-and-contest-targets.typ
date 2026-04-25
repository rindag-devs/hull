#import "../book.typ": book-page

#show: book-page.with(title: "Problem and Contest Targets")

= Problem and Contest Targets

Targets package a fully evaluated problem or contest into a concrete directory or archive format.

== Introduction to Targets

Define targets in the `targets` attribute set of `problem.nix` or `contest.nix`. `default` is used when no target is specified.

```nix
# In problem.nix
{
  # ... other options

  targets = {
    # The default target, built by `hull build`
    default = hull.problemTarget.common;

    # A target for the Hydro OJ system
    hydro = hull.problemTarget.hydro { /* Hydro-specific options */ };

    # A target for the UOJ system
    uoj = hull.problemTarget.uoj { /* UOJ-specific options */ };
  };
}
```

Hull includes built-in targets for local inspection and judge-specific packaging.

== Built-in Problem Targets

Problem targets operate on a single problem's configuration.

=== `common`

`hull.problemTarget.common` packages one problem into a readable local layout.

- *`data/`*: Contains all test case inputs and their corresponding standard answer files.
- *`solution/`*: Contains detailed judging results for every solution.
- *`checker.20.cpp`, `validator.20.cpp`, etc.*: Source code for core programs.
- *`overview.pdf`*: An automatically generated technical report of the problem, including test case analysis and solution performance.

=== `hydro`

`hull.problemTarget.hydro` packages one problem for #link("https://hydro.ac/")[Hydro-OJ].

- *`problem.yaml`*: Top-level metadata for the problem.
- *`testdata/config.yaml`*: Detailed judging configuration, including subtasks, time/memory limits, and paths to checker/validator programs.
- *`testdata/`*: Contains test data files, checker, validator, and other files required for judging.
- *`additional_file/`*: Contains files visible to participants, such as sample cases or grader source code.

=== `hydroCustom`

`hull.problemTarget.hydroCustom` packages one problem as a custom Hydro bundle.

- `Custom` here is part of the target name.
- It denotes a target that preserves Hull's full custom judging workflow instead of converting the problem into one fixed built-in judging route.
- It includes a bundled Hull runtime, a static `proot`, custom judger runners, and problem data.
- It keeps Hull's custom scheduling inside the bundle and exposes one outer testcase to Hydro.
- It requires judge resource limits and language settings that fit the bundled runtime.

=== `lemon`

`hull.problemTarget.lemon` packages one problem for #link("https://github.com/Project-LemonLime/Project_LemonLime")[Project LemonLime].

- *`<problem-name>.cdf`*: A JSON file containing all metadata, test case configurations, and contestant information.
- *`data/<problem-name>/`*: Contains test data and the native checker executable.
- *`source/<contestant-name>/<problem-name>/`*: Contains source files for solutions, organized by contestant name.

=== `lemonCustom`

`hull.problemTarget.lemonCustom` packages one problem as a custom Lemon bundle.

- `Custom` here is part of the target name.
- It denotes a target that preserves Hull's full custom judging workflow instead of converting the problem into one fixed built-in judging route.
- It includes a bundled Hull runtime, custom judger runners, and problem data.
- It keeps Hull's custom scheduling inside the bundle and exposes one outer testcase to Lemon.

=== `uoj`

`hull.problemTarget.uoj` packages one problem for #link("https://uoj.ac/")[Universal Online Judge].

- *`problem.conf`*: The main configuration file defining subtasks, scoring, and resource limits.
- *`<problem-name>1.in`, `<problem-name>1.out`, etc.*: Test data files following UOJ's naming convention.
- *`chk.20.cpp`, `val.20.cpp`*: Checker and validator source files.

=== `uojCustom`

`hull.problemTarget.uojCustom` packages one problem as a custom UOJ bundle.

- `Custom` here is part of the target name.
- It denotes a target that preserves Hull's full custom judging workflow instead of converting the problem into one fixed built-in judging route.
- It includes a bundled Hull runtime, custom judger runners, and problem data.
- It accepts `targetSystem`.
- The default `targetSystem` is `x86_64-linux`.

== Built-in Contest Targets

Contest targets package multiple problems into one contest output.

=== `common`

`hull.contestTarget.common` builds one selected problem target for each problem and places each output in its own subdirectory.

```nix
# In contest.nix
{
  # ...
  problems = [ ./aPlusB ./anotherProblem ];

  targets.default = hull.contestTarget.common {
    # This tells the contest target to build the "default" target
    # from each individual problem's configuration.
    problemTarget = "default";
  };
}
```

When built, this target produces a directory like this:

```plain
result/
├── aPlusB/         # <-- Output of the 'default' target for aPlusB
└── anotherProblem/ # <-- Output of the 'default' target for anotherProblem
```

=== `lemon`

`hull.contestTarget.lemon` merges per-problem Lemon outputs into one contest package.

- It combines all individual `.cdf` files into a single, contest-wide `.cdf` file.
- It merges all `data/` directories into one.
- It merges all `source/` directories, preserving the contestant-based structure.

This creates a complete contest package ready to be imported into Lemon.

=== `lemonCustom`

`hull.contestTarget.lemonCustom` merges per-problem `lemonCustom` outputs into one contest package.

- It merges all per-problem custom Lemon bundles into one contest output.
- It preserves the bundled Hull runtime and custom judging assets for each problem.
- It preserves the contestant-based source layout required by Lemon.

=== `cnoiParticipant`

`hull.contestTarget.cnoiParticipant` packages a contestant bundle with statements, samples, participant-visible files, and optional offline self-eval tools.

- It gathers all sample cases from each problem.
- It includes any participant-visible files (e.g., graders, skeleton code).
- It can build one PDF booklet for all problem statements.
- It accepts `archive = null | "tar.xz" | "zip"`.
- The default `archive` is `null`, which outputs a directory.
- It accepts `targetSystem`.
- The default `targetSystem` is `x86_64-linux`.

== Writing a Custom Target

Custom targets can be defined directly in `problem.nix` or `contest.nix`.

=== The Target Interface

A target is an attribute set with `_type` and `__functor`.

The structure of a target attribute set is as follows:

```nix
{
  # A mandatory type identifier for Hull's module system.
  # Use "hullProblemTarget" for problem targets.
  # Use "hullContestTarget" for contest targets.
  _type = "hullProblemTarget";

  /*
    The core logic of the target. This function is the "functor".
    It receives two arguments:
    1. `self`: A reference to the attribute set itself, allowing access
       to any custom options you define for the target.
    2. `config`: The fully evaluated problem or contest configuration.
  */
  __functor = self: config:
    # This function MUST return a Nix derivation.
    pkgs.runCommandLocal "..." { } ''
      # ... shell script to build the package ...
    '';

  # You can add your own custom options here.
  # customOption = "defaultValue";
}
```

The output of the derivation returned by `__functor` (`$out`) will be the final packaged directory.

=== Custom Problem Target Example

Let's create a simple problem target named `minimal`. This target will package only the test data and the source code of the main correct solution.

```nix
# In problem.nix
{
  # ... other problem options

  targets = {
    default = hull.problemTarget.common;

    # Our custom target
    minimal = {
      _type = "hullProblemTarget";
      __functor = self: problem:
        pkgs.runCommandLocal "hull-problemTargetOutput-${problem.name}-minimal" { } ''
          # The script inside this string is executed by the shell to build the package.
          # The `$out` variable refers to the output path of the derivation.

          # 1. Create the directory structure.
          mkdir -p $out/data $out/solution

          # 2. Copy the main correct solution's source code.
          #    We can access any value from the `problem` configuration here.
          cp ${problem.mainCorrectSolution.src} $out/solution/std.cpp

          # 3. Iterate over all test cases and copy their data.
          #    `lib.concatMapStringsSep` is a Nix function that generates a shell
          #    script snippet for each test case.
          ${lib.concatMapStringsSep "\n" (tc: ''
            cp ${tc.data.input} $out/data/${tc.name}.in
            cp ${tc.data.outputs}/output $out/data/${tc.name}.out
          '') (builtins.attrValues problem.testCases)}
        '';
    };
  };
}
```

=== Making Targets Configurable

The functor pattern allows you to create configurable targets. Let's modify our `minimal` target to allow customizing the name of the solution file.

```nix
# In problem.nix
{
  # ...

  targets = {
    # ...
    minimal = (
      # Options for the target are defined in a function that returns the attrset.
      { solutionFileName ? "std.cpp" }:
      {
        _type = "hullProblemTarget";
        __functor = self: problem:
          pkgs.runCommandLocal "hull-problemTargetOutput-${problem.name}-minimal" { } ''
            mkdir -p $out/data $out/solution

            # Use the custom option from the `self` argument.
            cp ${problem.mainCorrectSolution.src} $out/solution/${self.solutionFileName}

            # ... (rest of the script is the same)
            ${lib.concatMapStringsSep "\n" (tc: ''
              cp ${tc.data.input} $out/data/${tc.name}.in
              cp ${tc.data.outputs}/output $out/data/${tc.name}.out
            '') (builtins.attrValues problem.testCases)}
          '';

        # The option is part of the target attribute set.
        inherit solutionFileName;
      }
    ) { solutionFileName = "main_solution.cpp"; };
  };
}
```

In this advanced example, we wrap the target definition in a function to accept arguments. The `solutionFileName` is passed into the attribute set and can be accessed via `self.solutionFileName` inside the `__functor`. This is the same pattern used by Hull's built-in targets like `hull.problemTarget.hydro`.

=== Custom Contest Target Example

The principle for contest targets is identical, but the `config` object received by `__functor` is the contest configuration. It contains a list of problems under `config.problems`.

Let's create a custom contest target that generates a simple `index.html` file listing all the problems.

```nix
# In contest.nix
{
  # ... other contest options

  targets = {
    default = hull.contestTarget.common { problemTarget = "default"; };

    # Our custom web target
    web = {
      _type = "hullContestTarget";
      __functor = self: contest:
        pkgs.runCommandLocal "hull-contestTargetOutput-${contest.name}-web" { } ''
          mkdir $out
          echo "<h1>${contest.displayName.en}</h1>" > $out/index.html
          echo "<ul>" >> $out/index.html

          # Iterate over the list of problems in the contest.
          ${lib.concatMapStringsSep "\n" (p: ''
            # For each problem `p`, we can access its own configuration via `p.config`.
            echo "<li>${p.config.displayName.en} (${p.config.name})</li>" >> $out/index.html
          '') contest.problems}

          echo "</ul>" >> $out/index.html
        '';
    };
  };
}
```

This example demonstrates iterating over `contest.problems`. For each problem `p` in the list, we access its configuration via `p.config` to retrieve its name and display name, which are then written into the `index.html` file.
