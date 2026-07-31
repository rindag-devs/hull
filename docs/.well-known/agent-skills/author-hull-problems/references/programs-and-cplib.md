# Programs And CPLib

## Contents

- Program roles and dependencies
- Shared problem definitions
- Solution
- Validator
- Checker
- Generator
- Interactor and grader
- Reproducibility

## Program Roles And Dependencies

Apply the role-based language defaults from `SKILL.md` unless the user specifies otherwise. All correct, brute-force, intermediate, and wrong programs count as solutions; validators, checkers, generators, interactors, graders, and shared headers count as non-solution programs.

Use CPLib for generators, validators, checkers, and interactors. By default, depend only on CPLib and the C/C++ standard library. Discover the installed CPLib API from the project dependency, Hull documentation, or a user-provided source; never assume a machine-specific checkout path.

## Shared Problem Definitions

Keep input models, parsing, constraint constants, trait definitions, and reusable problem structures shared by the checker and validator in a matching `problem.*.hpp`. Include the same definitions in an interactor when applicable. Keep component entry points thin. Duplicated bounds or parsers can drift and are forbidden when they express the same contract.

## Solution

For the intended solution, provide:

- The algorithm and the invariant or recurrence that makes it correct.
- A proof covering all branches and boundary cases.
- Exact asymptotic time and memory complexity in the relevant variables.
- An implementation matching the proof rather than relying on undocumented behavior.

Unless the problem is trivial or a brute force is harder in both reasoning and implementation than the intended solution, implement a pure brute force. Also implement useful intermediate complexities that correspond to proposed subtasks or plausible unintended approaches. Give each implementation an expected subtask outcome in Hull configuration.

Do not make suboptimal solutions artificial by inserting sleeps or deliberate failures. They must compute correct answers on the inputs they finish. Do not create a cosmetically altered copy of the intended solution as an independent oracle.

Write compact, direct, and performance-conscious code. Use bit operations, `inline`, `__int128`, and appropriate compiler builtins when they materially simplify the algorithm or satisfy its bounds. Do not include `bits/stdc++.h`; include the required standard headers. Do not add recovery logic for invalid input or impossible states that the validator excludes.

By default, keep each solution self-contained; include only standard-library headers and, for special problem types, libraries or headers explicitly required by the statement, such as a provided grader header.

Choose I/O from the worst-case data volume. For input large enough that parsing overhead can affect the limit, use a dedicated scanner backed by `fread`. For large output, accumulate text in a buffer and emit it in large blocks with `fwrite`. Use `scanf`/`printf` or unsynchronized `cin`/`cout` only when the maximum I/O volume is comfortably small. Interactive solutions must instead follow the protocol's required flush points and must not defer judge-dependent output.

When the statement bounds give a safe compile-time capacity and that capacity fits the memory limit, prefer fixed-capacity arrays with static storage duration over dynamic allocation. Derive each capacity from a named bound and include indexing or sentinel slack explicitly. Use dynamic containers only when a safe capacity is unavailable, static allocation would waste substantial memory, or variable lifetime is algorithmically useful; reserve known capacity and avoid repeated allocation.

Prefer primitive numeric types, arrays, and purpose-built node or edge records over allocator-heavy nested containers. Avoid dynamic polymorphism, shared ownership and exceptions unless the algorithm specifically needs them. Select integer widths from proven value bounds.

## Validator

Make the validator accept exactly the statement's input language. Validate every token, separator, count, range, character set, decimal precision, aggregate bound, structural guarantee, and end of file. Emit traits from verified semantic properties, not assumptions based on generator identity.

For floating-point input, explicitly require finite values unless NaN or infinity is legal. A range comparison alone may fail to reject NaN.

## Checker

Use token comparison only for unique exact output where it fully captures correctness. Write a checker for non-unique, constructive, optimization, or floating-point output.

Parse contestant output strictly enough to reject malformed or extra output while accepting all formats permitted by the statement. Validate a construction semantically rather than comparing it with one stored construction.

For floating-point output, reject non-finite values unless explicitly legal and apply the statement's finite absolute-or-relative tolerance. Avoid division by zero when computing relative error. Keep checker behavior and statement wording identical at equality boundaries.

## Generator

Use CPLib's generator initializer and args. Implement each independently variable dimension and mode from the data plan as a distinct, composable argument. Ensure output is determined entirely by the complete command-line argument sequence.

Do not call `rand`, `time`, `std::uniform_int_distribution`, or any API whose exact runtime behavior is unspecified for reproducible generation. Do not use a manual ambient seed. Preserve the exact argument order and textual form because CPLib's deterministic random stream may derive from the complete raw command line.

## Interactor And Grader

Implement the protocol defined in the problem contract exactly. Keep interactor parsing and validator definitions shared where possible.

## Reproducibility

For every program, avoid dependence on implementation-defined behavior, unspecified iteration order, uninitialized values, wall-clock time, process state, locale, or runtime-randomized APIs. Using an API such as `std::unordered_map` is allowed only when the result does not depend on its iteration order.
