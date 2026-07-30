#import "/templates/page.typ": page

#show: page.with(
  title: "Custom Judgers",
  summary: "Define custom Hull judgers for multi-stage, interactive, complex scoring, or custom workflow problems.",
)

= Custom Judgers

Hull includes `batch`, `stdioInteraction`, and `answerOnly`. A problem can also define a custom judger.

`nix/test/problem/newYearGreeting/judger.nix` is a complete example.

== Built-in Runtime Models

- `batch` gives the contestant only stdin, stdout, and stderr. It does not predeclare writable contestant files or treat a fixed file as stdout.
- `stdioInteraction` runs the contestant and interactor in one deterministic session. Two bounded 64 KiB pipes connect their standard streams. A connected protocol deadlock produces `time_limit_exceeded` and is recorded in the session report.
- `answerOnly` evaluates submitted files without executing a contestant program.

For both executing models, the contestant receives the test case's tick, memory, and file-size limits. The tick limit bounds executed work, while the memory limit bounds WASM linear memory and the execution stack. `fileSizeLimit` bounds each contestant-controlled regular file or pipe independently: stdout and stderr in `batch`, and the contestant-to-interactor pipe and contestant stderr in `stdioInteraction`. The interactor is a trusted problem component and uses Hull's tool limits.

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
  judger =
    let
      solutionRequest = required_accepted: {
        report_path = "run-report.json";
        files = [
          {
            name = "stdin";
            kind = "regular";
            host_path = hull.runWasm.dynamicString "HULL_INPUT_PATH";
            max_permissions = 4;
            size_limit = config.fileSizeLimit;
          }
          {
            name = "stdout";
            kind = "regular";
            host_path = "stdout";
            max_permissions = 2;
            size_limit = config.fileSizeLimit;
          }
          {
            name = "stderr";
            kind = "regular";
            host_path = null;
            max_permissions = 2;
            size_limit = config.fileSizeLimit;
          }
        ];
        programs = [
          {
            name = "solution";
            wasm_path = hull.runWasm.dynamicString "HULL_SOLUTION_EXECUTABLE";
            arguments = [ ];
            tick_limit = hull.runWasm.dynamicNumber "HULL_TICK_LIMIT";
            memory_limit = hull.runWasm.dynamicNumber "HULL_MEMORY_LIMIT";
            inherit required_accepted;
            file_system = {
              directories = [
                {
                  path = ".";
                  permissions = 5;
                }
              ];
              bindings = [ ];
            };
            initial_descriptors = [
              {
                file = "stdin";
                permissions = 4;
              }
              {
                file = "stdout";
                permissions = 2;
              }
              {
                file = "stderr";
                permissions = 2;
              }
            ];
          }
        ];
      };
    in
    {
      _type = "hullJudger";

      prepareSolution = hull.judger.writeShellApplication {
        name = "hull-judger-${config.name}-prepareSolution";
        inheritPath = false;
        runtimeInputs =
          { targetPkgs, ... }:
          [
            targetPkgs.coreutils
            targetPkgs.jq
          ];
        text = { targetHull, ... }: ''
          ${targetHull.compile.executableMatchScript {
            languages = config.languages;
            srcExpr = ''"$HULL_SOLUTION_SRC"'';
            outExpr = ''"$HULL_PREPARED_SOLUTION_EXECUTABLE_PATH"'';
            includes = config.includes;
            extraObjects = [ ];
          }}

          jq -nc \
            --arg src "$HULL_SOLUTION_SRC" \
            --arg executable "$HULL_PREPARED_SOLUTION_EXECUTABLE_PATH" \
            '{ src: $src, executable: { path: $executable, drv_path: null } }' > "$HULL_REPORT_PATH"
        '';
      };

      generateOutputs = hull.judger.writeShellApplication {
        name = "hull-judger-${config.name}-generateOutputs";
        inheritPath = false;
        runtimeInputs = { targetPkgs, ... }: [ targetPkgs.coreutils ];
        text = { targetHull, ... }: ''
          ${targetHull.runWasm.script {
            request = solutionRequest true;
          }}

          mkdir -p "$HULL_OUTPUTS_DIR"
          install -Tm644 stdout "$HULL_OUTPUTS_DIR/output"
        '';
      };

      judge = hull.judger.writeShellApplication {
        name = "hull-judger-${config.name}-judge";
        inheritPath = false;
        runtimeInputs =
          { targetPkgs, ... }:
          [
            targetPkgs.coreutils
            targetPkgs.jq
          ];
        text = { targetHull, ... }: ''
          ${targetHull.runWasm.script {
            request = solutionRequest false;
          }}

          install -Tm644 stdout "$HULL_OUTPUTS_DIR/output"

          status=$(jq -r '.results[] | select(.program == "solution") | .status' run-report.json)
          message=$(jq -r '.results[] | select(.program == "solution") | .error_message // ""' run-report.json)

          jq -nc \
            --arg status "$status" \
            --argjson score "$(test "$status" = accepted && printf 1.0 || printf 0.0)" \
            --arg message "$message" \
            --argjson tick "$(jq '.results[] | select(.program == "solution") | .tick' run-report.json)" \
            --argjson memory "$(jq '.results[] | select(.program == "solution") | .memory' run-report.json)" \
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

`hull.runWasm.script` accepts one strict session request. Request objects and enum strings use `snake_case`, unknown fields are rejected, and every program must declare its complete descriptor and filesystem view. Input and output payloads stay in host files rather than JSON. Source WASM at `wasm_path` is authoritative; callers do not supply native compiled artifacts.

The top-level request fields are:

#table(
  columns: 3,
  table.header([Field], [Type], [Meaning]),
  [`report_path`], [path], [Destination for the small JSON session report.],
  [`files`], [array], [Named regular files and pipes shared by the session.],

  [`programs`],
  [nonempty array],
  [Programs in deterministic request and scheduling order.],
)

Every program object has these required fields:

#table(
  columns: 3,
  table.header([Field], [Type], [Meaning]),
  [`name`], [string], [Unique result and deadlock-report name.],
  [`wasm_path`], [path], [Authoritative core Wasm module.],
  [`arguments`], [string array], [Arguments after Hull's synthetic `argv[0]`.],
  [`tick_limit`],
  [integer or `"tool"`],
  [Maximum deterministic execution ticks.],

  [`memory_limit`],
  [integer or `"tool"`],
  [Linear-memory and guest-stack byte ceiling.],

  [`required_accepted`],
  [boolean],
  [Whether this result must be accepted for the generated shell command to succeed.],

  [`file_system`], [object], [Complete declared guest path tree.],

  [`initial_descriptors`], [array], [Initial fd 0, 1, 2, then fd 4 and above.],
)

Relative `report_path`, `host_path`, and `wasm_path` values resolve from the generated request file's directory. Use `hull.runWasm.dynamicString "ENVIRONMENT_NAME"` or `dynamicNumber` when a value must be substituted from the runner environment at execution time; ordinary Nix strings and numbers are fixed while evaluating the derivation.

=== Session Files

Every file has a unique `name`, a `kind`, and a mandatory `size_limit`. Use an explicit byte count for contestant-controlled files. The exact string `"tool"` selects Hull's trusted-tool ceiling and is reserved for trusted problem components.

A regular file has this shape:

```nix
{
  name = "data";
  kind = "regular";
  host_path = hull.runWasm.dynamicString "HULL_INPUT_PATH";
  max_permissions = 4;
  size_limit = config.fileSizeLimit;
}
```

`max_permissions` is the maximum permission set granted by the regular file: `0` for none, `2` for write, `4` for read, or `6` for read-write. Every descriptor and filesystem binding that references the file must grant a subset of this value. Execute permission is not supported.

`host_path` may be `null`, producing an anonymous sparse in-memory regular file. A read-capable host mapping must name an existing regular file and snapshots it before execution. A write-only mapping starts empty and its destination may be absent. Guest writes remain private during execution; a writable mapped regular file is materialized and atomically committed after the session reaches a runtime terminal result. Setup failures do not truncate or replace its destination.

A regular file's `size_limit` bounds its logical length, including snapshotted initial contents. Overwriting existing bytes does not consume a cumulative allowance. Sparse seeks and truncation do not allocate storage proportional to the limit.

A pipe has this shape:

```nix
{
  name = "requests";
  kind = "pipe";
  capacity = 64 * 1024;
  size_limit = config.fileSizeLimit;
}
```

`capacity` is the number of bytes that may be buffered before a writer blocks. `size_limit` instead bounds cumulative successful writes across the stream; consuming buffered bytes does not restore that allowance. Every pipe must have exactly one read endpoint and one write endpoint across the session.

Exceeding a regular file or pipe `size_limit`, or starting with an oversized referenced regular-file snapshot, produces `file_error`. Verdict precedence is `memory_limit_exceeded`, then `file_error`, then `time_limit_exceeded`, then runtime or exit semantics.

=== Initial Descriptors And Filesystem

`initial_descriptors` must contain at least three entries. Entries 0, 1, and 2 become fd 0, 1, and 2. Entry 3 is deliberately assigned fd 4, entry 4 is assigned fd 5, and so on: array indices from 3 onward are therefore one less than their guest fd.

fd 3 is skipped because it belongs to the guest filesystem root preopen. wasi-libc discovers Preview1 preopens by probing consecutive descriptors from fd 3 and stops at the first `BADF`. Giving fd 3 to an ordinary descriptor would make the root preopen unavailable or hide it from wasi-libc, so custom requests cannot repurpose fd 3.

A descriptor with `file = null` has null-device behavior: reads return EOF and writes are discarded. Its `permissions` still uses `0`, `2`, `4`, or `6`. A regular-file descriptor's permissions must be a subset of its file's `max_permissions`. Pipe read and write endpoint counts are inferred from these permission values; pipes cannot appear in filesystem bindings.

The fd 3 root preopen is always named `.`. `directories` declares the complete guest directory tree and must include that root. Directory `permissions` uses the Unix directory permission subset `0` for none, `1` for execute, `4` for read, or `5` for read-execute. `bindings` maps guest paths to regular files and grants `permissions` as a subset of each file's `max_permissions`. Directory permissions do not authorize undeclared files or directories.

Guest paths use `/`, are relative, and must be normalized: no leading or trailing slash, empty component, `.` component, or `..` component is allowed; the root itself is exactly `.`. Every parent directory must be explicitly declared, and no two directory or regular-file bindings may occupy the same path.

=== Ownership And Host-Path Invariants

File names and program names must be nonempty and unique. One regular file may have several writable descriptors or path aliases inside one program, but it cannot be writable by multiple programs. Every pipe has exactly one read-capable endpoint and one write-capable endpoint across all initial descriptors.

Host paths must not contain `..`. Hull resolves symlinks through the longest existing ancestor before checking overlap. `report_path`, distinct `wasm_path` values, and different mapped regular files must not be equal, contain one another, or alias through a symlink. This prevents a report, module, input, or output from replacing or exposing another session artifact.

=== Deterministic Time And Deadlocks

WASIp1 realtime and monotonic clocks are fixed at zero. A zero-time `poll_oneoff` clock subscription is ready immediately. A valid nonzero clock subscription is a blocking wait and cannot become clock-ready; another ready fd subscription in the same call may still wake it.

When all runnable progress stops, Hull reports `time_limit_exceeded` with the diagnostic `Protocol deadlock`. `deadlocks` records each minimal connected component using request-order `programs` and `pipes`. A pure nonzero clock wait has an empty `pipes` list.

=== Session Report

The JSON report at `report_path` contains one result per program in request order and a `deadlocks` array:

```json
{
  "results": [
    {
      "program": "solution",
      "status": "accepted",
      "tick": 123,
      "memory": 65536,
      "exit_code": 0,
      "error_message": null
    }
  ],
  "deadlocks": []
}
```

Runner statuses are `accepted`, `runtime_error`, `time_limit_exceeded`, `memory_limit_exceeded`, `file_error`, and `internal_error`. `required_accepted = true` makes a non-accepted program result fail the generated shell command after the report has been written.

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
    wasm = hull.compile.executable.drv {
      inherit (config) languages includes;
      src = solution.src;
      name = "${config.name}-solution-${solution.name}";
      extraObjects = [ ];
    };
  in
  {
    src = solution.src;
    executable = { path = toString wasm; drv_path = null; };
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
- `HULL_MEMORY_LIMIT`: WASM linear-memory and execution-stack limit in bytes for this test case.
- `HULL_FILE_SIZE_LIMIT`: byte limit for each contestant-controlled regular file or pipe.
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

`status` must be one of `accepted`, `wrong_answer`, `partially_correct`, `runtime_error`, `time_limit_exceeded`, `memory_limit_exceeded`, `file_error`, or `internal_error`. Preserve runtime limit statuses instead of converting them to a generic runtime error inside a Hull-owned judger.

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

- Set `inheritPath = false` on judger runners and declare their tools in `runtimeInputs`.
- Keep `prepareSolution` minimal and deterministic.
- Use environment variables such as `HULL_OUTPUTS_DIR` and `HULL_REPORT_PATH` as the only output contract.
- If a workflow needs multiple runtime steps, keep them in one shell script rather than branching in Nix evaluation.
- Read `nix/test/problem/newYearGreeting/judger.nix` for a complete custom multi-stage example.
