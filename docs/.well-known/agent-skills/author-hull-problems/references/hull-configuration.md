# Hull Configuration

## Contents

- Documentation discovery
- Workspace initialization
- Problem identity and documents
- Programs, solutions, and authoring
- File and directory naming
- Visibility
- Sample groups
- Groups, traits, and subtasks
- Targets
- Limits and units
- Configuration review

## Documentation Discovery

Discover exact option names and schemas through the Hull documentation-discovery skill and generated problem option references rather than inferring options from examples. Read the online best-practices page as Typst source at `https://hull.aberter0x3f.top/.well-known/agent-typst/getting-started/best-practices-and-conventions.typ`, not as HTML. For a custom judger or direct `hull.runWasm.script` request, read `https://hull.aberter0x3f.top/.well-known/agent-typst/advanced/custom-judgers.typ` before editing the configuration. That page is the schema and runtime-semantics authority.

## Workspace Initialization

Determine whether the selected directory already has a Hull problem structure. If not, initialize it from Hull's basic problem template. Preserve user files in a nonempty directory. Resolve direct path conflicts before initialization. Do not silently overwrite unrelated work.

Use the basic template as the starting point. Then remove unused example components. Do not switch to an underspecified custom layout. Keep generated artifacts and temporary measurements out of version control.

## Problem Identity And Documents

Use a concise camelCase machine identifier without spaces or punctuation. Keep display titles localized in statement documents. Register every requested statement language. Make sure that each document builds independently.

Statements use Typst. Place source files in the template's document structure and follow the exact pinned documentation for document options. Make statement documents participant-visible as required for distribution. This exception does not imply program visibility.

An editorial is a document under `document/editorial/<language-code>.typ`. Register one for each required editorial language. Keep it participant-invisible by default.

## Programs, Solutions, And Authoring

A **program** is either a **solution** or an **authoring** program. Solutions are contestant programs: the intended correct implementation, brute forces, intermediate complexity variants, and deliberately wrong programs. Authoring programs are all other programs: validators, checkers, generators, interactors, graders, and shared headers.

Solutions and authoring programs are configured independently in `problem.nix`:

- `solutionIncludes` / `solutionLanguages` apply to solutions. Register a grader header that solutions must include through `solutionIncludes`. Place it in `solution-include/`.
- `authoringIncludes` / `authoringLanguages` apply to authoring programs. Register shared definitions such as `problem.23.hpp` through `authoringIncludes`. Place them in `authoring-include/`. Solutions cannot see them.

A restriction on one role never leaks into the other. For example, `standardIncludes = false` on `solutionLanguages` adds `-nostdinc`. This does not affect authoring compilation.

Match physical source suffixes and configured languages to the standards selected under `SKILL.md` and [programs-and-cplib.md](programs-and-cplib.md). Register the main correct solution explicitly. Give suboptimal programs meaningful names.

Register each solution prediction using the exact status `accepted`, `wrong_answer`, `partially_correct`, `runtime_error`, `time_limit_exceeded`, `memory_limit_exceeded`, `file_error`, or `internal_error`.

Configure checkers, interactors, graders, and participant interfaces through the documented Hull mechanisms for each requested target. Keep participant distribution and target-specific packaging in the target configuration. Do not encode them in component programs.

## File And Directory Naming

The case of a file or directory name is decided by its content type, in priority order:

- *Code files* follow their language's identifier convention: C/C++ and Rust use `snake_case` (`std_optimized.17.cpp`), Nix uses `camelCase` (`batch.nix`, `problemModule/`), and other languages follow their ecosystem.
- *Typst documents* and files mainly consumed by Typst use `kebab-case` (`document/statement/en.typ`).
- *Subprojects* carry their language's rule over the whole subtree. Nested subprojects are judged independently.
- *Generic files and directories* (data, config, samples) use `kebab-case` (`data/hand-1.in`, `compile_flags.txt`).
- *Machine-interface suffixes* are exempt from case judgment: the dotted `.<version>.<ext>` tail (`std.17.cpp`) is the language-detection interface and is not a word separator.
- *Conventional names* are exempt: `README.md`, `LICENSE`, `flake.nix`, `Cargo.toml`, `.clang-format`.
- Code identifiers are not file names: the Nix `name` field stays `camelCase` even though the directory it names uses the content-type rule.

## Visibility

Do not set participant visibility for solutions, generators, validators, checkers, or interactors by default. Omission keeps them private under Hull defaults. Expose only files necessary for participation, such as a grader header, linkable library, or other required interface file.

Use the exact option type documented for each component. Program components and solutions/documents do not necessarily share one visibility type. Never copy a value between component kinds without checking the generated option reference.

## Sample Groups

Both `sample` and `sampleLarge` are testcase groups. Cases in `sample` are automatically embedded in generated statements. Cases in `sampleLarge` are distributed as samples but not embedded in the statement. Use this group for useful sample data that is too large to display inline.

## Groups, Traits, And Subtasks

Register the testcase groups designed under [data-subtasks-and-limits.md](data-subtasks-and-limits.md). Keep ordinary generated groups descriptive. Do not number them without meaning.

Configure subtasks from validator-emitted traits. Make sure that every testcase belongs to the intended subtasks.

When using partial scoring, make scores total `1.0`. Register every solution prediction for its intended subtask behavior before measurement.

## Targets

Configure exactly the target set resolved by the workflow, with no speculative adapters.

Read each requested target's documentation independently. Do not transfer grader files, interaction wiring, scoring semantics, archive layout, or packaging conventions from one downstream judge to another. A common target does not imply any platform-specific integration.

## Limits And Units

Set the tick limit in Hull ticks and the memory and file-size limits in bytes. The memory value bounds WASM linear memory and the execution stack independently. The file-size value applies independently to each contestant-owned regular file or pipe. Use the defaults from `SKILL.md` before calibration.

A regular file is limited by logical length, including its initial contents. A pipe is limited by cumulative successful writes.

Keep component-specific and target-specific limits consistent with the problem-level intent. Confirm generated option types and units. Do not assume traditional seconds or mebibytes.

## Configuration Review

Before building, inspect the effective configuration for:

- Exact source paths and language versions.
- One unambiguous main correct solution.
- Checker selection matching output semantics.
- Validator, generator, and authoring-include registration (`authoringIncludes`), plus any solution-facing `solutionIncludes`.
- Groups, traits, subtasks, scores, and solution predictions.
- Tick, memory-byte, and file-size-byte units.
- Private program visibility and necessary public documents/interfaces.
- Participant-invisible editorials for every required editorial language.
- Only requested targets.
