#import "../../book.typ": book-page

#show: book-page.with(title: "Problem and Contest Targets")

= Problem and Contest Targets

While `problem.nix` and `contest.nix` define the abstract logic of your problems, *targets* define their concrete, physical representation. A target is a Nix function that takes a fully evaluated problem or contest configuration and packages it into a specific directory structure, tailored for a particular online judge (OJ) system or use case.

This mechanism makes Hull problems highly portable. You can define a problem once and then generate packages for multiple platforms like Hydro, UOJ, or a generic local format, simply by defining different targets.

== Introduction to Targets

Targets are defined within the `targets` attribute set in your `problem.nix` or `contest.nix` file. The `default` target is special; it's the one built when you run `hull build` or `hull build-contest` without specifying a target name.

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

Hull provides a suite of built-in targets that cover common OJ systems and packaging needs.

== Built-in Problem Targets

Problem targets operate on a single problem's configuration.

=== `common`

The `hull.problemTarget.common` target is a general-purpose format that is useful for debugging, inspection, and local use. It organizes all components of the problem into a clear, human-readable directory structure.

- *`data/`*: Contains all test case inputs and their corresponding standard answer files.
- *`solution/`*: Contains detailed judging results for every solution.
- *`checker.20.cpp`, `validator.20.cpp`, etc.*: Source code for core programs.
- *`overview.pdf`*: An automatically generated technical report of the problem, including test case analysis and solution performance.

=== `hydro`

The `hull.problemTarget.hydro` target generates a package compatible with the #link("https://hydro.ac/")[Hydro-OJ] system. It creates the necessary YAML configuration files and directory structure that Hydro expects.

- *`problem.yaml`*: Top-level metadata for the problem.
- *`testdata/config.yaml`*: Detailed judging configuration, including subtasks, time/memory limits, and paths to checker/validator programs.
- *`testdata/`*: Contains test data files, checker, validator, and other files required for judging.
- *`additional_file/`*: Contains files visible to participants, such as sample cases or grader source code.

=== `lemon`

The `hull.problemTarget.lemon` target is designed for #link("https://github.com/Project-LemonLime/Project_LemonLime")[Project LemonLime]. It produces a directory structure centered around a `.cdf` (Contest Definition File) and organizes test data and contestant solutions accordingly.

- *`<problem-name>.cdf`*: A JSON file containing all metadata, test case configurations, and contestant information.
- *`data/<problem-name>/`*: Contains test data and the native checker executable.
- *`source/<contestant-name>/<problem-name>/`*: Contains source files for solutions, organized by contestant name.

=== `uoj`

The `hull.problemTarget.uoj` target creates a package for #link("https://uoj.ac/")[Universal Online Judge]. It generates a `problem.conf` file and renumbers test cases to fit UOJ's linear test point model.

- *`problem.conf`*: The main configuration file defining subtasks, scoring, and resource limits.
- *`<problem-name>1.in`, `<problem-name>1.out`, etc.*: Test data files following UOJ's naming convention.
- *`chk.20.cpp`, `val.20.cpp`*: Checker and validator source files.

== Built-in Contest Targets

Contest targets orchestrate the packaging of multiple problems into a single cohesive unit. They often work by invoking a specific problem target for each problem in the contest.

=== `common`

The `hull.contestTarget.common` target is the simplest contest packager. It builds a specified problem target for each problem and places the result into a corresponding subdirectory.

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

The `hull.contestTarget.lemon` target is more integrated. It requires each problem to have a `lemon` problem target. It then merges the outputs of all these problem targets into a single, unified Lemon contest package.

- It combines all individual `.cdf` files into a single, contest-wide `.cdf` file.
- It merges all `data/` directories into one.
- It merges all `source/` directories, preserving the contestant-based structure.

This creates a complete contest package ready to be imported into LemonLime.

=== `cnoiParticipant`

The `hull.contestTarget.cnoiParticipant` target is a specialized packager designed to create a distributable package for contestants, particularly for CNOI-series events. Its key features are:

- It gathers all sample cases from each problem.
- It includes any participant-visible files (e.g., graders, skeleton code).
- Most importantly, it uses Typst to compile a single, comprehensive PDF booklet containing the formatted problem statements for every problem in the contest, complete with a table of contents and consistent styling.

== Writing a Custom Target

For proprietary OJ systems or unique packaging requirements, you can write your own target directly in your `.nix` file.

=== The Target Interface

A target in Hull is not just a function, but a specific attribute set that follows a functor pattern. This allows for type checking and makes targets configurable.

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

        # The option is now part of the target's attribute set.
        inherit solutionFileName;
      }
    ) { solutionFileName = "main_solution.cpp"; }; # We can now configure it.
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
