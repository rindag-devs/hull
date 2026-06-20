#import "/templates/page.typ": page

#show: page.with(
  title: "Problem and Contest Targets",
  summary: "Learn how Hull problem and contest targets package evaluated artifacts for local inspection and judge systems.",
)

= Problem and Contest Targets

Targets package a fully evaluated problem or contest into a concrete directory or archive format.

== Introduction to Targets

Define targets in the `targets` attribute set of `problem.nix` or `contest.nix`. `default` is used when no target is specified.

```nix
# In problem.nix
{
  # ... other options

  targets = {
    # The default target, built by `hull build`.
    default = hull.problemTarget.common;

    # Batch export for Hydro-OJ.
    hydro = hull.problemTarget.hydro.batch {
      statements.en = "statement.en.pdf";
    };

    # Interactive export for UOJ.
    uoj = hull.problemTarget.uoj.stdioInteraction {
      twoStepInteraction = true;
    };

    # Answer-only export for CMS.
    cms = hull.problemTarget.cms.answerOnly { };
  };
}
```

Problem targets use two API shapes:

- Direct targets are already complete targets, such as `hull.problemTarget.common`, `hull.problemTarget.hydroCustom`, `hull.problemTarget.lemonCustom`, and `hull.problemTarget.uojCustom`.
- Judge-format targets are target families. Select a judging branch first, then pass that branch's options: `hull.problemTarget.hydro.batch { ... }`, `hull.problemTarget.uoj.stdioInteraction { ... }`, and so on.

This makes the judging model part of the target path instead of a string option inside the target arguments.

The branch name describes the judging protocol, not the judge platform:

- `batch` means Hull exports ordinary input/output test data with a checker.
- `stdioInteraction` means Hull exports a standard-input/standard-output interactive protocol.
- `answerOnly` means Hull exports a submit-answer or output-only package.

Platform-specific options remain arguments to the selected branch constructor. For example, UOJ's `twoStepInteraction` belongs on `hull.problemTarget.uoj.stdioInteraction { ... }`, while Lemon's `graderSrc` remains an option of `hull.problemTarget.lemon.batch { ... }`.

== Built-in Problem Targets

Problem targets operate on a single problem's evaluated configuration.

=== Local Inspection Target

==== `common`

`hull.problemTarget.common` packages one problem into a readable local layout.

- *`data/`*: Contains all test case inputs and their corresponding standard answer files.
- *`solution/`*: Contains detailed judging results for every solution.
- *`checker.20.cpp`, `validator.20.cpp`, etc.*: Source code for core programs.
- *`overview.pdf`*: An automatically generated technical report of the problem, including test case analysis and solution performance.

Use it directly:

```nix
targets.default = hull.problemTarget.common;
```

=== Judge-Format Target Families

These targets require a branch constructor. The common branches are:

- `.batch`: traditional input/output problems, including function-style grader problems when the target accepts grader files.
- `.stdioInteraction`: standard-input/standard-output interactive problems.
- `.answerOnly`: answer-only or submit-answer packages.

Not every judge backend supports every branch.

Branch support summary:

```text
target     batch  stdioInteraction  answerOnly
hydro      yes    yes               yes
uoj        yes    yes               yes
cms        yes    yes               yes
domjudge   yes    yes               no
luogu      yes    yes               yes
lemon      yes    no                yes
```

Use the constructor path shown by the matrix. There is no separate `type` option on these target families.

==== `hydro`

`hull.problemTarget.hydro.<branch>` packages one problem for #link("https://hydro.ac/")[Hydro-OJ].

Supported branches:

- `hull.problemTarget.hydro.batch { ... }`: emits Hydro `type = "default"`.
- `hull.problemTarget.hydro.stdioInteraction { ... }`: emits Hydro `type = "interactive"` and maps the checker as an interactor.
- `hull.problemTarget.hydro.answerOnly { ... }`: emits Hydro `type = "submit_answer"`.

Important outputs:

- *`problem.yaml`*: Top-level metadata for the problem.
- *`testdata/config.yaml`*: Detailed judging configuration, including subtasks, time/memory limits, and checker/interactor/validator paths.
- *`testdata/`*: Contains test data files, checker or interactor, validator, and files required for judging.
- *`additional_file/`*: Contains files visible to participants, such as sample cases, statements, participant-visible programs, or grader source code.

Example:

```nix
targets.hydro = hull.problemTarget.hydro.batch {
  statements.en = "statement.en.pdf";
  allowedLanguages = [ "cc.cc20" "cc.cc20o2" ];
};
```

==== `uoj`

`hull.problemTarget.uoj.<branch>` packages one problem for #link("https://uoj.ac/")[Universal Online Judge].

Supported branches:

- `hull.problemTarget.uoj.batch { ... }`: traditional UOJ package, with optional implementer files through `graderSrcs`.
- `hull.problemTarget.uoj.stdioInteraction { ... }`: enables `interaction_mode on`; accepts `twoStepInteraction`.
- `hull.problemTarget.uoj.answerOnly { ... }`: enables `submit_answer on`.

Important outputs:

- *`problem.conf`*: The main configuration file defining subtasks, scoring, samples, interaction mode, and resource limits.
- *`<problem-name>1.in`, `<problem-name>1.out`, etc.*: Test data files following UOJ's naming convention.
- *`chk.20.cpp`, `interactor20.cpp`, `val20.cpp`, `std20.cpp`*: Checker, interactor, validator, and main correct solution sources as required by the selected branch.
- *`require/`* and *`download/`*: Judge-side support files and participant-visible files.

Example:

```nix
targets.uoj = hull.problemTarget.uoj.stdioInteraction {
  twoStepInteraction = true;
  extraRequireFiles."protocol.h" = ./include/protocol.h;
};
```

==== `cms`

`hull.problemTarget.cms.<branch>` packages one problem for CMS.

Supported branches:

- `hull.problemTarget.cms.batch { ... }`: emits a CMS Batch task, with optional grader files through `graderSrcs`.
- `hull.problemTarget.cms.stdioInteraction { ... }`: emits a Communication-style package, installs the checker as `check/manager`, and installs grader files as stubs.
- `hull.problemTarget.cms.answerOnly { ... }`: emits an OutputOnly task.

Important outputs:

- *`task.yaml`*: CMS task metadata, resource limits, public samples, and branch-specific fields.
- *`input/`* and *`output/`*: Renumbered CMS test data.
- *`gen/GEN`*: Subtask and testcase structure.
- *`check/checker`* or *`check/manager`*: Native checker or communication manager.
- *`sol/`* and *`att/`*: Graders/stubs, extra solution files, attachments, samples, and participant-visible programs.

Example:

```nix
targets.cms = hull.problemTarget.cms.answerOnly {
  statements.english = "statement.en.pdf";
};
```

==== `domjudge`

`hull.problemTarget.domjudge.<branch>` packages one problem for DOMjudge.

Supported branches:

- `hull.problemTarget.domjudge.batch { ... }`: emits a custom validator/comparator package with `special_compare`.
- `hull.problemTarget.domjudge.stdioInteraction { ... }`: emits an interactive package with `special_run` and interactive validation metadata.

Important outputs:

- *`domjudge-problem.ini`* and *`problem.yaml`*: DOMjudge metadata and limits.
- *`data/sample/`* and *`data/secret/`*: Test data split by sample groups.
- *`output_validators/checker/run`*: Native checker or interactor executable.
- *`submissions/accepted/`*: Main correct solution source.
- *`attachments/`*: Participant-visible files and extra attachments.

Example:

```nix
targets.domjudge = hull.problemTarget.domjudge.batch {
  statement = "statement.en.pdf";
};
```

==== `luogu`

`hull.problemTarget.luogu.<branch>` packages one problem for Luogu.

Supported branches:

- `hull.problemTarget.luogu.batch { ... }`: traditional package, with optional `graderSrc` for grader-style interaction.
- `hull.problemTarget.luogu.stdioInteraction { ... }`: wraps the checker as an interactor and adds the interactive required tag.
- `hull.problemTarget.luogu.answerOnly { ... }`: emits answer-only metadata and required tags.

Important outputs:

- *`data.zip`*: Luogu upload archive containing `config.yml`, test data, checker wrapper, validator wrapper, and optional grader library.
- *`scoring-script.txt`*: Score aggregation script generated from Hull subtasks.
- *`required-tags.json`*: Tags that should be set on Luogu for the selected branch.

Luogu compiles custom programs with an older C++ standard. This target precompiles checker/interactor/validator programs and wraps the binaries into portable C wrappers.

Example:

```nix
targets.luogu = hull.problemTarget.luogu.batch {
  graderSrc = ./grader.cpp;
};
```

==== `lemon`

`hull.problemTarget.lemon.<branch>` packages one problem for #link("https://github.com/Project-LemonLime/Project_LemonLime")[Project LemonLime].

Supported branches:

- `hull.problemTarget.lemon.batch { ... }`: traditional package; if `graderSrc` is provided, the Lemon task type becomes grader interaction.
- `hull.problemTarget.lemon.answerOnly { ... }`: exports Hull answer files through Lemon's batch-compatible package shape.

Important outputs:

- *`<problem-name>.cdf`*: JSON contest/task file containing metadata, test case configurations, and contestant information.
- *`data/<problem-name>/`*: Test data, native checker executable, and optional grader or interaction library.
- *`source/<contestant-name>/<problem-name>/`*: Source files for configured solutions.

Example:

```nix
targets.lemon = hull.problemTarget.lemon.batch {
  graderSrc = ./grader.cpp;
  interactionLib = ./include/grader.h;
  interactionLibName = "grader.h";
  solutionExtNames.std = "cpp";
};
```

=== Custom-Judging Bundle Targets

These targets are direct targets, not branch constructors. They preserve Hull's custom runtime workflow instead of mapping the problem into one judge-native judging route.

==== `hydroCustom`

`hull.problemTarget.hydroCustom { ... }` packages one problem as a custom Hydro bundle.

- It includes a bundled Hull runtime, a static `proot`, custom judger runners, and problem data.
- It keeps Hull's custom scheduling inside the bundle and exposes one outer testcase to Hydro.
- It requires judge resource limits and language settings that fit the bundled runtime.

==== `lemonCustom`

`hull.problemTarget.lemonCustom { ... }` packages one problem as a custom Lemon bundle.

- It includes a bundled Hull runtime, custom judger runners, and problem data.
- It keeps Hull's custom scheduling inside the bundle and exposes one outer testcase to Lemon.

==== `uojCustom`

`hull.problemTarget.uojCustom { ... }` packages one problem as a custom UOJ bundle.

- It includes a bundled Hull runtime, custom judger runners, and problem data.
- It accepts `targetSystem`.
- The default `targetSystem` is `x86_64-linux`.

== Built-in Contest Targets

Contest targets package multiple problems into one contest output.

Contest targets do not choose a problem target branch directly. They choose a target name from each problem's `targets` set, then package those outputs together. Define branch-specific problem targets in every problem first, then point the contest target at that shared name.

For example, each problem can define:

```nix
targets = {
  default = hull.problemTarget.common;
  lemon = hull.problemTarget.lemon.batch { };
};
```

Then the contest can choose the `lemon` target name:

```nix
targets.lemon = hull.contestTarget.lemon { problemTarget = "lemon"; };
```

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

```text
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

In this advanced example, we wrap the target definition in a function to accept arguments. The `solutionFileName` is passed into the attribute set and can be accessed via `self.solutionFileName` inside the `__functor`. This is the same construction pattern used by Hull's built-in branch constructors such as `hull.problemTarget.hydro.batch`.

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
