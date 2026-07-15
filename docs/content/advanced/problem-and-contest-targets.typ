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

    # Hull-runtime export for Hydro-OJ.
    hydro = hull.problemTarget.hydro {
      statements.en = "statement.en.pdf";
    };

    # Hull-runtime export for UOJ.
    uoj = hull.problemTarget.uoj { };

    # Native CMS export.
    cmsLegacy = hull.problemTarget.legacy.cms.answerOnly { };
  };
}
```

Problem targets use two API shapes:

- Direct targets are already complete targets, such as `hull.problemTarget.common`, `hull.problemTarget.hydro`, `hull.problemTarget.lemon`, and `hull.problemTarget.uoj`.
- Legacy judge-format targets are target families under `hull.problemTarget.legacy`. Select a judging branch first, then pass that branch's options: `hull.problemTarget.legacy.hydro.batch { ... }`, `hull.problemTarget.legacy.uoj.stdioInteraction { ... }`, and so on.

This makes the judging model part of the target path instead of a string option inside the target arguments.

The branch name describes the judging protocol, not the judge platform:

- `batch` means Hull exports ordinary input/output test data with a checker.
- `stdioInteraction` means Hull exports a standard-input/standard-output interactive protocol.
- `answerOnly` means Hull exports a submit-answer or output-only package.

Platform-specific options remain arguments to the selected legacy branch constructor. For example, UOJ's `twoStepInteraction` belongs on `hull.problemTarget.legacy.uoj.stdioInteraction { ... }`, while Lemon's `graderSrc` remains an option of `hull.problemTarget.legacy.lemon.batch { ... }`.

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

=== Legacy Judge-Format Target Families

Legacy targets use the corresponding target platform's native judging flow instead of Hull's judging flow. They are useful when you need the platform to own the evaluation model directly, but they are not recommended unless that native flow is required.

These targets require a branch constructor under `hull.problemTarget.legacy`. The common branches are:

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

`hull.problemTarget.legacy.hydro.<branch>` packages one problem for #link("https://hydro.ac/")[Hydro-OJ] using Hydro's native judging flow.

Supported branches:

- `hull.problemTarget.legacy.hydro.batch { ... }`: emits Hydro `type = "default"`.
- `hull.problemTarget.legacy.hydro.stdioInteraction { ... }`: emits Hydro `type = "interactive"` and maps the checker as an interactor.
- `hull.problemTarget.legacy.hydro.answerOnly { ... }`: emits Hydro `type = "submit_answer"`.

Important outputs:

- *`problem.yaml`*: Top-level metadata for the problem.
- *`testdata/config.yaml`*: Detailed judging configuration, including subtasks, time/memory limits, and checker/interactor/validator paths.
- *`testdata/`*: Contains test data files, checker or interactor, validator, and files required for judging.
- *`additional_file/`*: Contains files visible to participants, such as sample cases, statements, participant-visible programs, or grader source code.

Example:

```nix
targets.hydroLegacy = hull.problemTarget.legacy.hydro.batch {
  statements.en = "statement.en.pdf";
  allowedLanguages = [ "cc.cc20" "cc.cc20o2" ];
};
```

==== `uoj`

`hull.problemTarget.legacy.uoj.<branch>` packages one problem for #link("https://uoj.ac/")[Universal Online Judge] using UOJ's native judging flow.

Supported branches:

- `hull.problemTarget.legacy.uoj.batch { ... }`: traditional UOJ package, with optional implementer files through `graderSrcs`.
- `hull.problemTarget.legacy.uoj.stdioInteraction { ... }`: enables `interaction_mode on`; accepts `twoStepInteraction`.
- `hull.problemTarget.legacy.uoj.answerOnly { ... }`: enables `submit_answer on`.

Important outputs:

- *`problem.conf`*: The main configuration file defining subtasks, scoring, samples, interaction mode, and resource limits.
- *`<problem-name>1.in`, `<problem-name>1.out`, etc.*: Test data files following UOJ's naming convention.
- *`chk.20.cpp`, `interactor20.cpp`, `val20.cpp`, `std20.cpp`*: Checker, interactor, validator, and main correct solution sources as required by the selected branch.
- *`require/`* and *`download/`*: Judge-side support files and participant-visible files.

Example:

```nix
targets.uojLegacy = hull.problemTarget.legacy.uoj.stdioInteraction {
  twoStepInteraction = true;
  extraRequireFiles."protocol.h" = ./include/protocol.h;
};
```

==== `cms`

`hull.problemTarget.legacy.cms.<branch>` packages one problem for CMS using CMS's native judging flow.

Supported branches:

- `hull.problemTarget.legacy.cms.batch { ... }`: emits a CMS Batch task, with optional grader files through `graderSrcs`.
- `hull.problemTarget.legacy.cms.stdioInteraction { ... }`: emits a Communication-style package, installs the checker as `check/manager`, and installs grader files as stubs.
- `hull.problemTarget.legacy.cms.answerOnly { ... }`: emits an OutputOnly task.

Important outputs:

- *`task.yaml`*: CMS task metadata, resource limits, public samples, and branch-specific fields.
- *`input/`* and *`output/`*: Renumbered CMS test data.
- *`gen/GEN`*: Subtask and testcase structure.
- *`check/checker`* or *`check/manager`*: Native checker or communication manager.
- *`sol/`* and *`att/`*: Graders/stubs, extra solution files, attachments, samples, and participant-visible programs.

Example:

```nix
targets.cmsLegacy = hull.problemTarget.legacy.cms.answerOnly {
  statements.english = "statement.en.pdf";
};
```

==== `domjudge`

`hull.problemTarget.legacy.domjudge.<branch>` packages one problem for DOMjudge using DOMjudge's native judging flow.

Supported branches:

- `hull.problemTarget.legacy.domjudge.batch { ... }`: emits a custom validator/comparator package with `special_compare`.
- `hull.problemTarget.legacy.domjudge.stdioInteraction { ... }`: emits an interactive package with `special_run` and interactive validation metadata.

Important outputs:

- *`domjudge-problem.ini`* and *`problem.yaml`*: DOMjudge metadata and limits.
- *`data/sample/`* and *`data/secret/`*: Test data split by sample groups.
- *`output_validators/checker/run`*: Native checker or interactor executable.
- *`submissions/accepted/`*: Main correct solution source.
- *`attachments/`*: Participant-visible files and extra attachments.

Example:

```nix
targets.domjudgeLegacy = hull.problemTarget.legacy.domjudge.batch {
  statement = "statement.en.pdf";
};
```

==== `luogu`

`hull.problemTarget.legacy.luogu.<branch>` packages one problem for Luogu using Luogu's native judging flow.

Supported branches:

- `hull.problemTarget.legacy.luogu.batch { ... }`: traditional package, with optional `graderSrc` for grader-style interaction.
- `hull.problemTarget.legacy.luogu.stdioInteraction { ... }`: wraps the checker as an interactor and adds the interactive required tag.
- `hull.problemTarget.legacy.luogu.answerOnly { ... }`: emits answer-only metadata and required tags.

Important outputs:

- *`data.zip`*: Luogu upload archive containing `config.yml`, test data, checker wrapper, validator wrapper, and optional grader library.
- *`scoring-script.txt`*: Score aggregation script generated from Hull subtasks.
- *`required-tags.json`*: Tags that should be set on Luogu for the selected branch.

Luogu compiles custom programs with an older C++ standard. This target precompiles checker/interactor/validator programs and wraps the binaries into portable C wrappers.

Example:

```nix
targets.luoguLegacy = hull.problemTarget.legacy.luogu.batch {
  graderSrc = ./grader.cpp;
};
```

==== `lemon`

`hull.problemTarget.legacy.lemon.<branch>` packages one problem for #link("https://github.com/Project-LemonLime/Project_LemonLime")[Project LemonLime] using Lemon's native judging flow.

Supported branches:

- `hull.problemTarget.legacy.lemon.batch { ... }`: traditional package; if `graderSrc` is provided, the Lemon task type becomes grader interaction.
- `hull.problemTarget.legacy.lemon.answerOnly { ... }`: exports Hull answer files through Lemon's batch-compatible package shape.

Important outputs:

- *`<problem-name>.cdf`*: JSON contest/task file containing metadata, test case configurations, and contestant information.
- *`data/<problem-name>/`*: Test data, native checker executable, and optional grader or interaction library.
- *`source/<contestant-name>/<problem-name>/`*: Source files for configured solutions.

Example:

```nix
targets.lemonLegacy = hull.problemTarget.legacy.lemon.batch {
  graderSrc = ./grader.cpp;
  interactionLib = ./include/grader.h;
  interactionLibName = "grader.h";
  solutionExtNames.std = "cpp";
};
```

=== Platform Targets

These targets are direct targets, not branch constructors. They preserve Hull's judging flow inside the target package instead of mapping the problem into one platform-native judging route.

Prefer these platform targets for ordinary use. Use legacy targets only when a platform-native evaluation model is specifically required.

==== `hydro`

`hull.problemTarget.hydro { ... }` packages one problem as a Hydro bundle that runs Hull's judging flow.

- It includes a bundled Hull runtime, a static `proot`, custom judger runners, and problem data.
- It carries static BusyBox and Zstandard executables for `targetSystem`; supported targets are `x86_64-linux` and `aarch64-linux`.
- `zstdCompressionLevel` is an integer from 1 through 22 and defaults to 19. Levels 20 through 22 use Zstandard's ultra mode.
- It keeps Hull's custom scheduling inside the bundle and exposes one outer testcase to Hydro.
- The Hydro platform must provide `/bin/bash` for the first script invocation; bundle extraction does not depend on host `tar` or `zstd`.
- It requires judge resource limits and language settings that fit the bundled runtime.

==== `lemon`

`hull.problemTarget.lemon { ... }` packages one problem as a Lemon bundle that runs Hull's judging flow.

- It includes a bundled Hull runtime, custom judger runners, and problem data.
- It keeps Hull's custom scheduling inside the bundle and exposes one outer testcase to Lemon.

==== `uoj`

`hull.problemTarget.uoj { ... }` packages one problem as a UOJ bundle that runs Hull's judging flow.

- It includes a bundled Hull runtime, custom judger runners, problem data, and static BusyBox and Zstandard executables.
- `targetSystem` selects `x86_64-linux` or `aarch64-linux` and defaults to `x86_64-linux`; the UOJ host must run binaries for the selected architecture.
- `zstdCompressionLevel` is an integer from 1 through 22 and defaults to 19. Levels 20 through 22 use Zstandard's ultra mode.
- The UOJ host must run Linux with unprivileged user namespaces enabled for `nix-user-chroot`.
- Set the problem `extra_config` to `{"dont_use_formatter": true}` before syncing data so UOJ's formatter does not modify packaged binary files.
- UOJ invokes the packaged Makefile before running the judger. Judging does not depend on host `tar`, `zstd`, or a compiler.

== Built-in Contest Targets

Contest targets package multiple problems into one contest output.

Contest targets do not choose a problem target branch directly. They choose a target name from each problem's `targets` set, then package those outputs together. Define branch-specific problem targets in every problem first, then point the contest target at that shared name.

For example, each problem can define:

```nix
targets = {
  default = hull.problemTarget.common;
  lemon = hull.problemTarget.lemon { };
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

`hull.contestTarget.lemon` merges per-problem `lemon` outputs into one contest package.

- It merges all per-problem Lemon bundles into one contest output.
- It preserves the bundled Hull runtime and judging assets for each problem.
- It preserves the contestant-based source layout required by Lemon.

=== `legacy.lemon`

`hull.contestTarget.legacy.lemon` merges per-problem `lemonLegacy` outputs into one contest package using Lemon's native judging flow.

Use it only when a contest package must rely on Lemon's native evaluation model. Prefer `hull.contestTarget.lemon` for ordinary Hull-managed judging.

=== `cnoiParticipant`

`hull.contestTarget.cnoiParticipant` packages a contestant bundle with statements, samples, participant-visible files, and optional offline self-eval tools.

- It gathers all sample cases from each problem.
- It includes any participant-visible files (e.g., graders, skeleton code).
- It can build one PDF booklet for all problem statements.
- `archive` accepts `null | "tar.xz" | "tar.zst" | "zip"` and defaults to `null`; `null` outputs a directory.
- `xzCompressionLevel` controls `tar.xz` compression, accepts integers from 0 through 9, and defaults to 6.
- `zstdCompressionLevel` applies to `tar.zst`, accepts integers from 1 through 22, and defaults to 19. Levels 20 through 22 use Zstandard's ultra mode.
- `zipCompressionLevel` controls `zip` compression, accepts integers from 0 through 9, and defaults to 9.
- Archive outputs require the consuming host to provide an extractor for the selected outer format; they do not carry archive bootstrap tools.
- It accepts `targetSystem`.
- The default `targetSystem` is `x86_64-linux`.

== Writing a User-Defined Target

User-defined targets can be defined directly in `problem.nix` or `contest.nix`.

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
       to any options you define for the target.
    2. `config`: The fully evaluated problem or contest configuration.
  */
  __functor = self: config:
    # This function MUST return a Nix derivation.
    pkgs.runCommandLocal "..." { } ''
      # ... shell script to build the package ...
    '';

  # You can add your own options here.
  # optionName = "defaultValue";
}
```

The output of the derivation returned by `__functor` (`$out`) will be the final packaged directory.

=== User-Defined Problem Target Example

Let's create a simple problem target named `minimal`. This target will package only the test data and the source code of the main correct solution.

```nix
# In problem.nix
{
  # ... other problem options

  targets = {
    default = hull.problemTarget.common;

    # Our user-defined target
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

            # Use the option from the `self` argument.
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

In this advanced example, we wrap the target definition in a function to accept arguments. The `solutionFileName` is passed into the attribute set and can be accessed via `self.solutionFileName` inside the `__functor`. This is the same construction pattern used by Hull's built-in branch constructors such as `hull.problemTarget.legacy.hydro.batch`.

=== User-Defined Contest Target Example

The principle for contest targets is identical, but the `config` object received by `__functor` is the contest configuration. It contains a list of problems under `config.problems`.

Let's create a user-defined contest target that generates a simple `index.html` file listing all the problems.

```nix
# In contest.nix
{
  # ... other contest options

  targets = {
    default = hull.contestTarget.common { problemTarget = "default"; };

    # Our user-defined web target
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
