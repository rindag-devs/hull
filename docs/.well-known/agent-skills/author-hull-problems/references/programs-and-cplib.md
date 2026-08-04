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

Apply the role-based language defaults from `SKILL.md` unless the user specifies otherwise. A **program** is either a **solution** or an **authoring** program. Solutions are the correct, brute-force, intermediate, and wrong contestant programs. Authoring programs are validators, checkers, generators, interactors, graders, and shared headers.

Solutions and authoring programs compile with separate languages and include directories: `solutionIncludes`/`solutionLanguages` and `authoringIncludes`/`authoringLanguages` in `problem.nix`. CPLib and `problem.*.hpp` belong in `authoring-include/`. They are reachable only by authoring programs. A solution sees only `solution-include/` and otherwise stays self-contained.

Use CPLib for generators, validators, checkers, and interactors. By default, depend only on CPLib and the C/C++ standard library. Discover the installed CPLib API from the project dependency, Hull documentation, or a user-provided source. Never assume a machine-specific checkout path.

## Shared Problem Definitions

Share input models, parsing, constraint constants, trait definitions, and reusable problem structures between the checker and validator. Put them in a matching `authoring-include/problem.*.hpp`. Include the same definitions in an interactor when applicable. Keep component entry points thin. Do not duplicate bounds or parsers that express the same contract. They can drift apart.

## Solution

For the intended solution, provide:

- The algorithm and the invariant or recurrence that makes it correct.
- A proof covering all branches and boundary cases.
- Exact asymptotic time and memory complexity in the relevant variables.
- An implementation matching the proof rather than relying on undocumented behavior.

Implement a pure brute force. Omit it only when the problem is trivial. Also omit it when a brute force is harder in both reasoning and implementation than the intended solution. Implement useful intermediate complexities that correspond to proposed subtasks or plausible unintended approaches. Give each implementation an expected subtask outcome in Hull configuration.

Do not make suboptimal solutions artificial by inserting sleeps or deliberate failures. They must compute correct answers on the inputs they finish. Do not create a cosmetically altered copy of the intended solution as an independent oracle.

Write compact, direct, and performance-conscious code. Use bit operations, `inline`, `__int128`, and appropriate compiler builtins when they materially simplify the algorithm or satisfy its bounds. Do not include `bits/stdc++.h`. Include the required standard headers. Do not add recovery logic for invalid input or impossible states that the validator excludes.

By default, keep each solution self-contained. Include only standard-library headers and any headers that the statement explicitly requires, such as a provided grader header. A grader header goes in `solution-include/` and is registered in `solutionIncludes`. It must not pull in `authoring-include/` content.

Choose I/O from the worst-case data volume. For input large enough that parsing overhead can affect the limit, use a dedicated scanner backed by `fread`. For large output, accumulate text in a buffer. Emit it in large blocks with `fwrite`. Use `scanf`/`printf` or unsynchronized `cin`/`cout` only when the maximum I/O volume is comfortably small. Interactive solutions must follow the protocol's required flush points. They must not defer judge-dependent output.

When the statement bounds give a safe compile-time capacity, prefer fixed-capacity arrays with static storage duration. Make sure that the capacity fits the memory limit. Derive each capacity from a named bound. Include indexing or sentinel slack explicitly. Use dynamic containers only when a safe capacity is unavailable. Use them also when static allocation wastes substantial memory or variable lifetime is algorithmically useful. Reserve known capacity. Avoid repeated allocation.

Prefer primitive numeric types, arrays, and purpose-built node or edge records over allocator-heavy nested containers. Unless the algorithm specifically needs them, avoid dynamic polymorphism, shared ownership, and exceptions. Select integer widths from proven value bounds.

## Validator

Make the validator accept exactly the statement's input language. Validate every token, separator, count, range, character set, decimal precision, aggregate bound, structural guarantee, and end of file. Emit traits from verified semantic properties, not assumptions based on generator identity.

For floating-point input, explicitly require finite values unless NaN or infinity is legal. A range comparison alone can fail to reject NaN.

## Checker

Use token comparison only for unique exact output where it fully captures correctness. Write a checker for non-unique, constructive, optimization, or floating-point output.

Parse contestant output strictly. Reject malformed or extra output. Accept all formats permitted by the statement. Validate a construction semantically. Do not compare it with one stored construction.

For floating-point output, reject non-finite values unless they are explicitly legal. Apply the statement's finite absolute-or-relative tolerance. When you compute relative error, avoid division by zero. Keep checker behavior and statement wording identical at equality boundaries.

## Generator

Use CPLib's generator initializer and args. Implement each independently variable dimension and mode from the data plan as a distinct, composable argument. Make sure that output depends only on the complete command-line argument sequence.

Do not call `rand`, `time`, `std::uniform_int_distribution`, or any API whose exact runtime behavior is unspecified for reproducible generation. Do not use a manual ambient seed. Preserve the exact argument order and textual form. CPLib's deterministic random stream can derive from the complete raw command line.

## Interactor And Grader

Implement the protocol defined in the problem contract exactly. Keep interactor parsing and validator definitions shared where possible.

## Reproducibility

Avoid dependence on implementation-defined behavior, unspecified iteration order, uninitialized values, wall-clock time, process state, locale, or runtime-randomized APIs. You can use an API such as `std::unordered_map` only when the result does not depend on its iteration order.
