#import "../../book.typ": book-page

#show: book-page.with(title: "Custom Judgers")

= Custom Judgers

While Hull's built-in judgers (`batch`, `stdioInteraction`, and `answerOnly`) cover a wide range of standard problem types, some problems require more complex evaluation logic. For these scenarios, Hull provides a powerful mechanism to define a completely custom judger directly within your `problem.nix`.

== When to Use a Custom Judger

You should consider writing a custom judger when your problem's evaluation process does not fit the standard models. Common use cases include:

- *Multi-stage Problems*: Problems where the evaluation involves multiple steps, such as an "encode" phase followed by a "decode" phase. The input for a later stage might depend on the output of an earlier one.
- *Special Interaction*: Problems that require interaction but do not use standard input/output, perhaps involving communication over named pipes or files with a custom interactor.
- *Complex Scoring*: Problems with scoring logic that cannot be expressed by simply summing or taking the minimum of test case scores within a subtask.
- *Dynamic Test Cases*: Scenarios where the test case for a solution is generated or modified based on the output of a previous run (though this is a very advanced and rare case).

The `newYearGreeting` problem in Hull's test suite is a perfect example of a multi-stage problem that requires a custom judger.

== The Judger Interface

A judger in Hull is a Nix function that you assign to the `judger` option in `problem.nix`. This function receives the problem's configuration (`config`) as an argument and must return an attribute set containing two specific functions: `generateOutputs` and `judge`.

Here is the basic skeleton of a custom judger:

```nix
# In problem.nix
{
  # ... other problem options

  judger = config: {
    _type = "hullJudger"; # Internal type identifier

    /*
      Generates the standard answer files for a given test case
      using the main correct solution.
    */
    generateOutputs = testCase: stdSolution:
      # This function must return a derivation.
      pkgs.runCommandLocal "hull-generateOutputs-${config.name}-${testCase.name}" { } ''
        # Script to generate answer files...
        mkdir $out
        # ...
      '';

    /*
      Judges a user's solution against a given test case.
    */
    judge = testCase: solution:
      # This function must also return a derivation.
      pkgs.runCommandLocal "hull-judge-${config.name}-${testCase.name}-${solution.name}"
        # Script to judge the solution...
        mkdir -p $out/outputs
        echo '{ "status": "accepted", "score": 1.0, ... }' > $out/report.json
        # ...
      '';
  };

  # ...
}
```

Let's break down the two required functions.

=== Implementing `generateOutputs`

The `generateOutputs` function is responsible for creating the standard answer files for a single test case.

- *Signature*: It takes two arguments:
  1. `testCase`: The attribute set for the test case being processed (from `config.testCases`).
  2. `stdSolution`: The attribute set for the solution marked with `mainCorrectSolution = true`.
- *Return Value*: It *must* return a Nix derivation. The output path of this derivation is expected to be a directory containing the standard answer files (e.g., `output`, `phase1.txt`).

=== Implementing `judge`

The `judge` function is the core of the judger. It defines the process for evaluating a single solution against a single test case.

- *Signature*: It takes two arguments:
  1. `testCase`: The attribute set for the test case.
  2. `solution`: The attribute set for the solution being judged.
- *Return Value*: It *must* return a Nix derivation. The output path of this derivation must be a directory containing:
  1. `report.json`: A JSON file detailing the judging result (status, score, tick, memory, message).
  2. `outputs/`: A subdirectory containing all output files produced by the solution.

== The Golden Rule: Avoiding "Import From Derivation" (IFD)

When writing a custom judger, there is one principle that is absolutely critical to follow: *your `judge` and `generateOutputs` functions must not cause an Import From Derivation (IFD).*

=== What is IFD and Why is it Harmful?

In Nix, evaluation (parsing and interpreting Nix code to figure out *what* to build) and building (actually running compilers and scripts) are two distinct phases. Nix's power comes from its ability to evaluate the entire dependency graph first, and then build everything that's needed in parallel.

An "Import From Derivation" occurs when the *evaluation* of a Nix expression depends on the *built output* of another derivation. When Nix encounters this, it has no choice but to pause the evaluation, build the required derivation, read its output, and only then resume evaluation.

This is disastrous for performance in Hull. The Nix evaluator is sequential. If your `judge` function for test case #1 needs to build something to figure out what to do next, it completely blocks the evaluation of the `judge` functions for test cases #2, #3, and so on. Your parallel build process degenerates into a slow, sequential chain reaction, defeating one of the primary benefits of using Nix.

As the official Nix manual states:
#align(
  left,
  rect(
    inset: 8pt,
    stroke: 1pt + color.luma(128),
    [
      Passing an expression `expr` that evaluates to a store path to any built-in function which reads from the filesystem constitutes Import From Derivation (IFD): `import expr`, `builtins.readFile expr`, etc.

      This has performance implications: Evaluation can only finish when all required store objects are realised. Since the Nix language evaluator is sequential, it only finds store paths to read from one at a time. While realisation is always parallel, in this case it cannot be done for all required store paths at once, and is therefore much slower than otherwise.
    ],
  ),
)

=== The Correct Pattern: Return a Derivation

The `judge` and `generateOutputs` functions should be "pure" from an evaluation perspective. Their only job is to construct and return a derivation (typically using `pkgs.runCommandLocal`) that describes the entire workflow. All the actual work—compiling, running programs, reading outputs, and making decisions—must happen *inside the shell script* of that returned derivation.

*Correct Example:*

```nix
judge = testCase: solution:
  pkgs.runCommandLocal "hull-judge-${config.name}-${testCase.name}-${solution.name}"
    # Step 1: Run the solution. The path to the compiled WASM is already known.
    # The `hull.runWasm.script` helper generates a script snippet.
    ${hull.runWasm.script {
      wasm = solution.cwasm;
      stdin = testCase.data.input;
      # ... other options
    }}

    # Step 2: Check the status from the run report.
    run_status=$(jq -r .status report.json)

    # Step 3: If the run was successful, run the checker.
    if [ "$run_status" == "accepted" ]; then
      ${hull.check.script {
        checkerWasm = config.checker.cwasm;
        input = testCase.data.input;
        output = "stdout"; # The output from the previous step
        answer = testCase.data.outputs + "/output";
      }}
      # ... process checker result ...
    fi

    # Step 4: Construct the final report.json and outputs/ directory.
    # ...
  '';
```
In this pattern, the `judge` function simply pieces together a shell script. Nix can evaluate this instantly without building anything. The complex, multi-step logic is deferred to the build phase, which Nix can then execute in parallel for all test cases.

=== The Anti-Pattern: IFD in Action

Here is what you must *never* do. Do not attempt to run a derivation and read its output from within the `judge` function itself.

*Incorrect Example (Causes IFD):*

```nix
# THIS IS WRONG! DO NOT DO THIS!
judge = testCase: solution:
  let
    # First, we define a derivation to run the solution.
    runDerivation = pkgs.runCommandLocal "run-solution" { } ''
      # ... script to run the solution and write status to $out ...
      ${hull.runWasm.script { /* ... */ }}
      jq -r .status report.json > $out
    '';

    # THIS IS THE IFD!
    # Nix must stop and build `runDerivation` to read its content.
    runStatus = builtins.readFile runDerivation;

  in
  # The rest of the logic depends on the result of the build.
  if runStatus == "accepted" then
    pkgs.runCommandLocal "check-derivation" { } ''
      # ... script to run the checker ...
    ''
  else
    pkgs.runCommandLocal "fail-derivation" { } ''
      # ... script to create a failed report ...
    '';
```
This code forces Nix to build `runDerivation` during evaluation, which will serialize your entire judging process and make it extremely slow. Always encapsulate the full workflow within a single derivation returned by `judge`.
