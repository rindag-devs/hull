# Programs And CPLib

## Contents

- Language and coding rules
- Correct and suboptimal solutions
- Shared problem definitions
- Validator
- Checker
- Generator
- Interactor and grader
- Component tests
- Reproducibility

## Language And Coding Rules

Apply the role-based language defaults from `SKILL.md` unless the user specifies otherwise. All correct, brute-force, intermediate, and wrong programs count as solutions; validators, checkers, generators, interactors, graders, and shared headers count as non-solution programs.

Write contest-style code: compact, direct, and performance-conscious. Fast input, bit operations, `inline`, `__int128`, and appropriate compiler builtins are acceptable. Do not include `bits/stdc++.h`; include the required standard headers. Do not add recovery logic for invalid input or impossible states that the validator excludes.

Use CPLib for generators, validators, checkers, and interactors. By default, depend only on CPLib and the C/C++ standard library. Discover the installed CPLib API from the project dependency, Hull documentation, or a user-provided source; never assume a machine-specific checkout path.

## Correct And Suboptimal Solutions

For the intended solution, provide:

- The algorithm and the invariant or recurrence that makes it correct.
- A proof covering all branches and boundary cases.
- Exact asymptotic time and memory complexity in the relevant variables.
- An implementation matching the proof rather than relying on undocumented behavior.

Unless the problem is trivial or a brute force is harder in both reasoning and implementation than the intended solution, implement a pure brute force. Also implement useful intermediate complexities that correspond to proposed subtasks or plausible unintended approaches. Give each implementation an expected subtask outcome in Hull configuration.

Do not make suboptimal solutions artificial by inserting sleeps or deliberate failures. They must compute correct answers on the inputs they finish. Do not create a cosmetically altered copy of the intended solution as an independent oracle.

## Shared Problem Definitions

Keep input models, parsing, constraint constants, trait definitions, and reusable problem structures shared by the checker and validator in a matching `problem.*.hpp`. Include the same definitions in an interactor when applicable. Keep component entry points thin. Duplicated bounds or parsers can drift and are forbidden when they express the same contract.

Use concise affirmative trait names. Prefer exact names such as `n_le_1000`, `a_ge_100`, `a_mod_2_eq_0`, `is_tree`, or `n_is_odd`. Avoid vague names such as `is_small` and negative names containing `not`; represent the negative case through an affirmative trait with value `false`.

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

Define the protocol as part of the problem contract: message order, flushing, query limit, termination, invalid queries, scoring, and failure handling. Keep interactor parsing and validator definitions shared where possible.

Configure an interactor through the Hull mechanism documented for the requested target. Configure participant distribution and target-specific packaging under [hull-configuration.md](hull-configuration.md).

## Component Tests

Add short, targeted tests for real failure modes in validators, checkers, and interactors. A useful test distinguishes a plausible bug: a missing bound, trailing token, malformed construction, tolerance boundary, NaN, query-limit violation, or protocol error.

Do not enumerate the full input domain, duplicate generator coverage, or add tests that only assert constants or code shape. Prefer the smallest input that proves the component accepts or rejects the intended case.

## Reproducibility

For every program, avoid dependence on implementation-defined behavior, unspecified iteration order, uninitialized values, wall-clock time, process state, locale, or runtime-randomized APIs. Using an API such as `std::unordered_map` is allowed only when the result does not depend on its iteration order.
