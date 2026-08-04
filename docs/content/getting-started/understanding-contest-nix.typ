#import "/templates/page.typ": page

#show: page.with(
  title: "Understanding contest.nix",
  summary: "Understand how contest.nix defines contest metadata, included problems, packaging targets, and contest builds.",
)

= Understanding `contest.nix`

`contest.nix` defines one contest.

== A Minimal Example

Minimal example:

```nix
{
  hull,
  ...
}:
{
  # Basic metadata for the contest
  name = "myFirstContest";
  displayName.en = "my first contest";

  # A list of paths to the problems included in this contest.
  # Hull will evaluate the problem definition in each of these directories.
  problems = [
    ./problems/aPlusB
    ./problems/anotherProblem
  ];

  # Defines how to package the final contest.
  targets = {
    # The 'default' target is the one built by `hull build-contest`.
    default = hull.contestTarget.common {
      # This tells the contest target to find and use the 'default'
      # target from each individual problem's `problem.nix` file.
      problemTarget = "default";
    };
  };
}
```

== Core Options

This section breaks down the essential options available in `contest.nix`.

=== Basic Metadata

These options define the fundamental properties of your contest.

- `name`: A unique, machine-readable identifier for the contest (for example, `day1`, `finalRound`). It must be a simple string without spaces or special characters. It is used for internal references.
- `displayName`: An attribute set containing human-readable titles for the contest in different languages. The keys are language codes (for example, `en`, `zh`).

=== Defining Problems

This is the most important part of the file, where you specify which problems are part of the contest.

- `problems`: A list of problems.

```nix
{
  problems = [
    ../problems/aPlusB  # Path to the 'aPlusB' problem directory
    ../problems/hello   # Path to the 'hello' problem directory
  ];
}
```

=== Defining Targets

Similar to `problem.nix`, the `targets` attribute set defines different packaging formats for the contest. A contest target specifies how to structure the final output directory. It combines the outputs of all included problems.

- `targets`: An attribute set where each attribute defines a packaging target. The `default` target is special. It is the one built by the `hull build-contest` command without additional arguments. It is evaluated after runtime analysis for each problem. Hull provides built-in contest targets such as `common`, `lemon` and `cnoiParticipant`.

== Building the Contest

Once your `contest.nix` is configured, you can build the entire package using the `hull build-contest` command.

*Prerequisite:* You must run this command from within the Nix development shell (`nix develop`).

```bash
hull build-contest
```

By default, this command looks for a `default` contest defined in your `flake.nix` (which usually points to `./contest.nix`). Then it builds the `default` target of that contest. If you have multiple contests or targets, you can specify them with flags:

```bash
# Build the 'day1' contest using its 'lemon' target
hull build-contest --contest day1 --target lemon
```

Upon successful completion, Hull creates a `result` symbolic link in your project directory. The structure of this output depends on the target used. For the `hull.contestTarget.common` target shown in the example, the output looks like this:

```
result/
├── aPlusB/
│   ├── data/
│   ├── solution/
│   ├── overview.pdf
│   └── ... (contents of the 'default' target for the aPlusB problem)
└── anotherProblem/
    ├── data/
    ├── solution/
    ├── overview.pdf
    └── ... (contents of the 'default' target for the anotherProblem)
```

== Relationship Between Contest and Problem Targets

Contest targets often collect outputs of problem targets.

Consider the `hull.contestTarget.common` target. It takes an argument named `problemTarget`.

```nix
targets.default = hull.contestTarget.common {
  problemTarget = "default";
};
```

When you run `hull build-contest`, the following happens:

1. Hull loads the contest metadata and resolves the list of problems in the contest.
2. It analyzes each problem through the Rust runtime, including validator checks, official output generation, and solution judging.
3. It injects the analyzed runtime data into each problem configuration.
4. It builds the selected problem target for every problem.
5. It evaluates the contest target and combines the packaged problem outputs into the final contest directory.

Use `-j` / `--jobs` to control how many problems Hull analyzes in parallel. Arguments after `--` are forwarded to the final `nix build`. Debugging flags such as `--show-trace` remain available.

Contest packaging is composed from problem targets.
