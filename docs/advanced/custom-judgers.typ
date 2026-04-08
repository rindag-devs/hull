#import "../book.typ": book-page

#show: book-page.with(title: "Custom Judgers")

= Custom Judgers

Hull includes `batch`, `stdioInteraction`, and `answerOnly`. A problem can also define a custom judger.

`nix/test/problem/newYearGreeting/judger.nix` is a complete example.

== When to Use a Custom Judger

Use a custom judger when the built-in models do not fit the evaluation workflow.

- *Multi-stage Problems*: Problems where evaluation has multiple dependent phases, such as "encode first, then decode based on the first output".
- *Special Interaction*: Problems that need custom communication over files, FIFOs, or a protocol that does not match the built-in interactive model.
- *Complex Scoring*: Problems whose scoring logic is not naturally expressed by the standard checker result aggregation.
- *Custom Workflow Packaging*: Problems where you want the whole judging workflow to be representable as a standalone judger runner.

== The Judger Interface

A judger is an attribute set assigned to `judger`. It must contain `_type = "hullJudger"`. It usually contains:

- `prepareSolution`: a runner or function that prepares one solution
- `generateOutputs`: a runner or function that generates official outputs for one test case
- `judge`: a runner or function that judges one `(solution, testCase)` pair

Basic skeleton:

```nix
{
  judger = {
      _type = "hullJudger";

      prepareSolution = hull.judger.writeShellApplication {
        name = "hull-judger-${config.name}-prepareSolution";
        inheritPath = false;
        runtimeInputs = { targetPkgs, ... }: [ targetPkgs.coreutils targetPkgs.jq ];
        text = { targetHull, ... }: ''
          ${targetHull.compile.executableMatchScript {
            languages = targetHull.language.retarget { inherit targetHull; } config.languages;
            srcExpr = ''"$HULL_SOLUTION_SRC"'';
            outExpr = ''"$HULL_PREPARED_SOLUTION_EXECUTABLE_PATH"'';
            includes = config.includes;
            extraObjects = [ ];
          }}

          jq -nc \
            --arg src "$HULL_SOLUTION_SRC" \
            --arg executable "$HULL_PREPARED_SOLUTION_EXECUTABLE_PATH" \
            '{ src: $src, executable: { path: $executable, drvPath: null } }' > "$HULL_REPORT_PATH"
        '';
      };

      generateOutputs = hull.judger.writeShellApplication {
        name = "hull-judger-${config.name}-generateOutputs";
        inheritPath = false;
        runtimeInputs = { targetPkgs, ... }: [ targetPkgs.coreutils ];
        text = { targetHull, ... }: ''
          ${targetHull.runWasm.script {
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

      judge = hull.judger.writeShellApplication {
        name = "hull-judger-${config.name}-judge";
        inheritPath = false;
        runtimeInputs = { targetPkgs, ... }: [ targetPkgs.coreutils targetPkgs.jq ];
        text = { targetHull, ... }: ''
          ${targetHull.runWasm.script {
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

`prepareSolution` prepares one solution for the packaged runners.

Typical tasks:

- keep `src` when the runner needs the original source
- produce `executable` when the runner needs an executable path

For example, a source-only problem may use:

```nix
prepareSolution = solution: {
  src = solution.src;
};
```

Example with an executable path:

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
    executable = { path = toString wasm; drvPath = null; };
  };
```

== `generateOutputs`

`generateOutputs` runs once for each test case, using the solution with `mainCorrectSolution = true`.

Environment variables:

- `HULL_MODE`: `generateOutputs` or `judge`.
- `HULL_TESTCASE_NAME`: the test case name.
- `HULL_SOLUTION_NAME`: the solution name.
- `HULL_INPUT_PATH`: the input file for this test case.
- `HULL_TICK_LIMIT`: tick limit for this test case.
- `HULL_MEMORY_LIMIT`: memory limit for this test case.
- `HULL_SOLUTION_SRC`: source path returned by `prepareSolution`, or the original solution source.
- `HULL_SOLUTION_EXECUTABLE`: executable path returned by `prepareSolution` when present.
- `HULL_OUTPUTS_DIR`: directory where the runner must place generated outputs.

`HULL_REPORT_PATH` is unset in `generateOutputs` mode.

If a runner needs a deterministic salt derived from the test case name, it can compute one inside the script, for example:

```sh
testCaseNameHash=$(printf '%s' "$HULL_TESTCASE_NAME" | sha256sum | cut -d' ' -f1)
```

== `judge`

`judge` runs once per `(testCase, solution)` pair.

The runner must:

- write all produced output files into `$HULL_OUTPUTS_DIR`
- write the final judge report JSON to `$HULL_REPORT_PATH`

Report format:

```json
{
  "status": "accepted",
  "score": 1.0,
  "message": "",
  "tick": 12345,
  "memory": 1048576
}
```

Additional variable in `judge` mode:

- `HULL_OFFICIAL_OUTPUTS_DIR`: directory containing the official outputs generated for this test case

This is the directory you should compare against when running a checker or implementing custom scoring logic.

== Using Helper Scripts

Inside a packaged runner, the most common helpers are:

- `hull.runWasm.script` to execute a WASM program
- `hull.check.script` to run the checker
- `hull.validate.script` to run the validator

Example:

```nix
${hull.check.script {
  checkerWasm = config.checker.wasm;
  input = "$HULL_INPUT_PATH";
  output = "$run_stdout";
  answer = "$HULL_OFFICIAL_OUTPUTS_DIR/output";
}}
```

Keep runtime logic inside the runner.

== Practical Advice

- Set `inheritPath = false` on judger runners and declare all required tools in `runtimeInputs`.
- Keep `prepareSolution` minimal and deterministic.
- Use environment variables such as `HULL_OUTPUTS_DIR` and `HULL_REPORT_PATH` as the only output contract.
- If a workflow needs multiple runtime steps, keep them in one shell script rather than branching in Nix evaluation.
- Read `nix/test/problem/newYearGreeting/judger.nix` for a complete custom multi-stage example.
