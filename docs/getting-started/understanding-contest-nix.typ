#import "../book.typ": book-page

#show: book-page.with(title: "Understanding contest.nix")

= Understanding `contest.nix`

While the `problem.nix` file is the heart of a single problem, the `contest.nix` file is the conductor that orchestrates multiple problems into a single, cohesive contest package. It is a declarative file used to group problems, define contest-wide metadata, and specify how the entire contest should be built and packaged for different platforms.

Compared to `problem.nix`, the structure of `contest.nix` is significantly simpler, as its primary role is aggregation.

== A Minimal Example

Here is a complete example of a `contest.nix` file. It defines a contest with two problems and specifies a single, common way to package them.

```nix
{
  hull,
  ...
}:
{
  # Basic metadata for the contest
  name = "myFirstContest";
  displayName.en = "My First Contest";

  # A list of paths to the problems included in this contest.
  # Hull will evaluate the problem definition in each of these directories.
  problems = map (p: hull.evalProblem p { }) [
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

Let's break down the essential options available in `contest.nix`.

=== Basic Metadata

These options define the fundamental properties of your contest.

- `name`: A unique, machine-readable identifier for the contest (e.g., `day1`, `finalRound`). It should be a simple string without spaces or special characters and is used for internal references.
- `displayName`: An attribute set containing human-readable titles for the contest in different languages. The keys are language codes (e.g., `en`, `zh`).

=== Defining Problems

This is the most important part of the file, where you specify which problems are part of the contest.

- `problems`: A list of evaluated problems.

```nix
{
  problems = map (p: hull.evalProblem p { }) [
    ../problems/aPlusB  # Path to the 'aPlusB' problem directory
    ../problems/hello   # Path to the 'hello' problem directory
  ];
}
```

=== Defining Targets

Similar to `problem.nix`, the `targets` attribute set defines different packaging formats for the contest. A contest target specifies how to structure the final output directory, combining the outputs of all included problems.

- `targets`: An attribute set where each attribute defines a new packaging target. The `default` target is special, as it's the one built by the `hull build-contest` command without additional arguments. Hull provides built-in contest targets like `common`, `lemon` and `cnoiParticipant`.

== Building the Contest

Once your `contest.nix` is configured, you can build the entire package using the `hull build-contest` command.

*Prerequisite:* This command must be run from within the Nix development shell (`nix develop`).

```bash
hull build-contest
```

By default, this command looks for a `default` contest defined in your `flake.nix` (which usually points to `./contest.nix`) and builds its `default` target. If you have multiple contests or targets, you can specify them with flags:

```bash
# Build the 'day1' contest using its 'lemon' target
hull build-contest --contest day1 --target lemon
```

Upon successful completion, Hull creates a `result` symbolic link in your project directory. The structure of this output depends on the target used. For the `hull.contestTarget.common` target shown in the example, the output would look like this:

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

It is crucial to understand that a contest target's job is often to collect and arrange the outputs of individual *problem targets*.

Consider the `hull.contestTarget.common` target. It takes an argument named `problemTarget`.

```nix
targets.default = hull.contestTarget.common {
  problemTarget = "default";
};
```

When you run `hull build-contest`, the following happens:

1. Hull starts building the contest's `default` target.
2. This target (`hull.contestTarget.common`) knows it needs to process each problem in the `problems` list.
3. For each problem (e.g., `aPlusB`), it looks into its `problem.nix` file for the target specified by `problemTarget` (in this case, the `default` problem target).
4. It builds that problem target.
5. Finally, it copies the entire output of the problem target into a subdirectory named after the problem (`result/aPlusB/`).

This powerful mechanism allows you to create complex contest packages by composing pre-defined problem packages, ensuring consistency and modularity.
