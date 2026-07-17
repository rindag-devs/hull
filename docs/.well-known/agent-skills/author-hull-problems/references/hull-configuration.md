# Hull Configuration

## Contents

- Documentation discovery
- Workspace initialization
- Problem identity and documents
- Programs and languages
- Visibility
- Groups, traits, and subtasks
- Targets
- Limits and units
- Configuration review

## Documentation Discovery

Discover exact option names and schemas through the Hull documentation-discovery skill and generated problem option references rather than inferring options from examples. Read the online best-practices page as Typst source at `https://hull.aberter0x3f.top/.well-known/agent-typst/getting-started/best-practices-and-conventions.typ`, not as HTML.

## Workspace Initialization

Determine whether the selected directory already has a Hull problem structure. If not, initialize it from Hull's basic problem template. Preserve user files in a nonempty directory and resolve direct path conflicts before initialization; do not silently overwrite unrelated work.

Use the basic template as the starting point, then remove unused example components rather than switching to an underspecified custom layout. Keep generated artifacts and temporary measurements out of version control.

## Problem Identity And Documents

Use a concise camelCase machine identifier without spaces or punctuation. Keep display titles localized in statement documents. Register every requested statement language and ensure each document is independently buildable.

Statements use Typst. Place source files in the template's document structure and follow the exact pinned documentation for document options. Make statement documents participant-visible as required for distribution; this exception does not imply program visibility.

## Programs And Languages

Match physical source suffixes and configured languages to the standards selected under `SKILL.md` and [programs-and-cplib.md](programs-and-cplib.md). Register the main correct solution explicitly and give suboptimal programs meaningful names and solution predictions.

## Visibility

Do not set participant visibility for solutions, generators, validators, checkers, or interactors by default; omission keeps them private under Hull defaults. Expose only files necessary for participation, such as a grader header, linkable library, or other required interface file.

Use the exact option type documented for each component. Program components and solutions/documents do not necessarily share one visibility type, so never copy a value between component kinds without checking the generated option reference.

## Groups, Traits, And Subtasks

Register the testcase groups designed under [data-subtasks-and-limits.md](data-subtasks-and-limits.md). Keep ordinary generated groups descriptive rather than numbering them without meaning.

Configure subtasks from validator-emitted traits and ensure every testcase belongs to the intended subtasks.

When using partial scoring, make scores total `1.0` and register every solution prediction for its intended subtask behavior before measurement.

## Targets

Configure exactly the target set resolved by the workflow, with no speculative adapters.

Read each requested target's documentation independently. Do not transfer grader files, interaction wiring, scoring semantics, archive layout, or packaging conventions from one downstream judge to another. A common target does not imply any platform-specific integration.

## Limits And Units

Set the time limit in Hull ticks and the memory limit in bytes. Use the defaults from `SKILL.md` before calibration.

Keep component-specific and target-specific limits consistent with the problem-level intent. Confirm generated option types and units instead of assuming traditional seconds or mebibytes.

## Configuration Review

Before building, inspect the effective configuration for:

- Exact source paths and language versions.
- One unambiguous main correct solution.
- Checker selection matching output semantics.
- Validator, generator, and shared include registration.
- Groups, traits, subtasks, scores, and solution predictions.
- Tick and byte units.
- Private program visibility and necessary public documents/interfaces.
- Only requested targets.
