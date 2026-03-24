#import "../book.typ": book-page

#show: book-page.with(title: "Custom Judgers")

= Custom Judgers

While Hull's built-in judgers (`batch`, `stdioInteraction`, and `answerOnly`) cover many common problem types, some problems require a fully custom evaluation pipeline. For these scenarios, Hull lets you define a custom judger directly in your `problem.nix`.

Custom judgers are expressed as *packaged runners*. A judger exposes executable derivations that Hull runs through a uniform environment contract. This keeps the interface compact and makes the whole judging workflow easy to package.

The `newYearGreeting` problem in Hull's test suite is a complete example of this style.

== When to Use a Custom Judger

You should consider writing a custom judger when your problem's evaluation process does not fit the built-in models. Common use cases include:

- *Multi-stage Problems*: Problems where evaluation has multiple dependent phases, such as "encode first, then decode based on the first output".
- *Special Interaction*: Problems that need custom communication over files, FIFOs, or a protocol that does not match the built-in interactive model.
- *Complex Scoring*: Problems whose scoring logic is not naturally expressed by the standard checker result aggregation.
- *Custom Workflow Packaging*: Problems where you want the whole judging workflow to be representable as a standalone judger runner.

== The Judger Interface

A judger is an attribute set assigned to the `judger` option. It must contain `_type = "hullJudger"`, and it usually contains three fields:

- `prepareSolution`: Converts a solution into the artifacts that the runner needs, such as a compiled `cwasm` executable.
- `generateOutputs`: An executable derivation that Hull runs to generate the official outputs for one test case.
- `judge`: An executable derivation that Hull runs to judge one solution on one test case.

Here is the basic skeleton:

```nix
{
  judger =
    let
      helperWasm = hull.compile.executable {
        inherit (config) languages includes;
        src = ./helper.20.cpp;
        name = "${config.name}-helper";
        extraObjects = [ ];
      };
      helperCwasm = hull.compile.cwasm {
        name = "${config.name}-helper";
        wasm = helperWasm;
      };
    in
    {
      _type = "hullJudger";

      prepareSolution =
        solution:
        let
          solutionWasm = hull.compile.executable {
            inherit (config) languages includes;
            src = solution.src;
            name = "${config.name}-solution-${solution.name}";
            extraObjects = [ ];
          };
        in
        {
          src = solution.src;
          executable = hull.compile.cwasm {
            name = "${config.name}-solution-${solution.name}";
            wasm = solutionWasm;
          };
        };

      generateOutputs = pkgs.writeShellApplication {
        name = "hull-judger-${config.name}-generateOutputs";
        inheritPath = false;
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          ${hull.runWasm.script {
            wasm = "$HULL_SOLUTION_EXECUTABLE";
            stdin = "$HULL_INPUT_PATH";
            tickLimit = "$HULL_TICK_LIMIT";
            memoryLimit = "$HULL_MEMORY_LIMIT";
            ensureAccepted = true;
          }}

          mkdir -p "$HULL_OUTPUTS_DIR"
          install -Tm644 stdout "$HULL_OUTPUTS_DIR/output"
        '';
      };

      judge = pkgs.writeShellApplication {
        name = "hull-judger-${config.name}-judge";
        inheritPath = false;
        runtimeInputs = [ pkgs.coreutils pkgs.jq ];
        text = ''
          ${hull.runWasm.script {
            wasm = "$HULL_SOLUTION_EXECUTABLE";
            stdin = "$HULL_INPUT_PATH";
            tickLimit = "$HULL_TICK_LIMIT";
            memoryLimit = "$HULL_MEMORY_LIMIT";
            ensureAccepted = false;
          }}

          install -Tm644 stdout "$HULL_OUTPUTS_DIR/output"

          jq -nc \
            --arg status accepted \
            --argjson score 1.0 \
            --arg message "" \
            --argjson tick "$(jq .tick report.json)" \
            --argjson memory "$(jq .memory report.json)" \
            '{
              status: $status,
              score: $score,
              message: $message,
              tick: $tick,
              memory: $memory
            }' > "$HULL_REPORT_PATH"
        '';
      };
    };
}
```

== `prepareSolution`

`prepareSolution` is evaluated by Hull during judger setup. Its job is to translate a solution definition into the store artifacts that the runner expects.

Typical responsibilities:

- Keep `src = solution.src` if the raw source file is needed by the runner.
- Compile the solution to WASM and then to `cwasm` if the runner wants an executable.
- Return an attribute set that may contain fields such as `src` and `executable`.

For example, a source-only problem may use:

```nix
prepareSolution = solution: {
  src = solution.src;
};
```

while a runnable problem usually produces:

```nix
prepareSolution =
  solution:
  let
    wasm = hull.compile.executable {
      inherit (config) languages includes;
      src = solution.src;
      name = "${config.name}-solution-${solution.name}";
      extraObjects = [ ];
    };
  in
  {
    src = solution.src;
    executable = hull.compile.cwasm {
      name = "${config.name}-solution-${solution.name}";
      inherit wasm;
    };
  };
```

== `generateOutputs`

`generateOutputs` is an executable derivation.

Hull runs it once for each test case, using the solution marked with `mainCorrectSolution = true`. The runner must write all official output files into `$HULL_OUTPUTS_DIR`.

During execution, Hull provides these environment variables:

- `HULL_MODE`: `generateOutputs` or `judge`.
- `HULL_TESTCASE_NAME`: the test case name.
- `HULL_SOLUTION_NAME`: the solution name.
- `HULL_INPUT_PATH`: the input file for this test case.
- `HULL_TICK_LIMIT`: tick limit for this test case.
- `HULL_MEMORY_LIMIT`: memory limit for this test case.
- `HULL_SOLUTION_SRC`: source path returned by `prepareSolution`, or the original solution source.
- `HULL_SOLUTION_EXECUTABLE`: executable path returned by `prepareSolution` when present.
- `HULL_OUTPUTS_DIR`: directory where the runner must place generated outputs.

In `generateOutputs` mode, `HULL_REPORT_PATH` is unset because no report file is expected.

If a runner needs a deterministic salt derived from the test case name, it can compute one inside the script, for example:

```sh
testCaseNameHash=$(printf '%s' "$HULL_TESTCASE_NAME" | sha256sum | cut -d' ' -f1)
```

== `judge`

`judge` is an executable derivation. Hull runs it once per `(testCase, solution)` pair.

The runner must:

- write all produced output files into `$HULL_OUTPUTS_DIR`
- write the final judge report JSON to `$HULL_REPORT_PATH`

Hull uses the following report format:

```json
{
  "status": "accepted",
  "score": 1.0,
  "message": "",
  "tick": 12345,
  "memory": 1048576
}
```

In `judge` mode, Hull additionally provides:

- `HULL_OFFICIAL_OUTPUTS_DIR`: directory containing the official outputs generated for this test case

This is the directory you should compare against when running a checker or implementing custom scoring logic.

== Using Helper Scripts

Inside a packaged runner, the most common helpers are:

- `hull.runWasm.script` to execute a compiled WASM or CWASM program
- `hull.check.script` to run the checker
- `hull.validate.script` to run the validator

For example:

```nix
${hull.check.script {
  checkerWasm = config.checker.cwasm;
  input = "$HULL_INPUT_PATH";
  output = "$run_stdout";
  answer = "$HULL_OFFICIAL_OUTPUTS_DIR/output";
}}
```

Because the actual work happens inside the shell script, you can describe arbitrarily complex judging pipelines while keeping Nix evaluation declarative.

== The Golden Rule

Keep Nix evaluation declarative.

Evaluation should only assemble derivations and dependency graphs. All steps that inspect outputs, run programs, or branch on runtime data must happen inside the returned runner.

=== Correct Pattern

This is the correct pattern:

```nix
judge = pkgs.writeShellApplication {
  name = "hull-judger-demo-judge";
  inheritPath = false;
  runtimeInputs = [ pkgs.coreutils pkgs.jq ];
  text = ''
    ${hull.runWasm.script {
      wasm = "$HULL_SOLUTION_EXECUTABLE";
      stdin = "$HULL_INPUT_PATH";
      tickLimit = "$HULL_TICK_LIMIT";
      memoryLimit = "$HULL_MEMORY_LIMIT";
      ensureAccepted = false;
    }}

    run_status=$(jq -r .status report.json)

    if [ "$run_status" = accepted ]; then
      ${hull.check.script {
        checkerWasm = config.checker.cwasm;
        input = "$HULL_INPUT_PATH";
        output = "$PWD/stdout";
        answer = "$HULL_OFFICIAL_OUTPUTS_DIR/output";
      }}
    fi

    # produce $HULL_REPORT_PATH here
  '';
};
```

Nix evaluation only sees an executable derivation. The operational logic stays inside the runner.

=== Anti-Pattern

The following is wrong:

```nix
# THIS IS WRONG! DO NOT DO THIS!
let
  runDerivation = pkgs.runCommandLocal "run-solution" { } ''
    ${hull.runWasm.script {
      wasm = someCompiledProgram;
      stdin = someInput;
    }}
    jq -r .status report.json > $out
  '';

  # This forces evaluation to wait for a build result.
  runStatus = builtins.readFile runDerivation;
in
if runStatus == "accepted" then ... else ...
```

This forces evaluation to depend on build results and defeats Hull's runtime orchestration model.

== Practical Advice

- Set `inheritPath = false` on judger runners and declare all required tools in `runtimeInputs`.
- Keep `prepareSolution` minimal and deterministic.
- Use environment variables such as `HULL_OUTPUTS_DIR` and `HULL_REPORT_PATH` as the only output contract.
- If a workflow needs multiple runtime steps, keep them in one shell script rather than branching in Nix evaluation.
- Read `nix/test/problem/newYearGreeting/judger.nix` for a complete custom multi-stage example.
