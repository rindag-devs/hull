---
name: author-hull-problems
description: Create, complete, adapt, and verify competitive programming problems for Hull from an idea, a partial draft, an existing problem, or an existing problem workspace. Use when an agent must turn incomplete problem-authoring input into a buildable Hull problem, including formal Typst statements, intended and brute-force solutions, CPLib validators/checkers/generators/interactors, tests, traits, subtasks, targets, generated data, and calibrated resource limits.
---

# Author Hull Problems

Produce a complete problem rather than a proposal. Treat omitted ordinary details as work to perform, not reasons to stop.

## Load The References

Read each reference before working on the corresponding phase:

- Read [problem-design-and-statement.md](references/problem-design-and-statement.md) before defining semantics, constraints, input/output, or statement text.
- Read [programs-and-cplib.md](references/programs-and-cplib.md) before writing solutions, validators, checkers, generators, interactors, graders, or shared headers.
- Read [data-subtasks-and-limits.md](references/data-subtasks-and-limits.md) before designing traits, subtasks, scores, test groups, generators, data, or resource limits.
- Read [hull-configuration.md](references/hull-configuration.md) before initializing a workspace or editing `flake.nix`, `problem.nix`, targets, visibility, languages, or documents.
- Read [verification.md](references/verification.md) before testing components, calibrating predictions, building, reviewing, or delivering the problem.

## Defaults

Apply these defaults unless the user gives a different requirement:

| Item | Default |
| --- | --- |
| Display language | The language used by the user in the conversation. |
| Time limit | `10000000000` ticks. |
| Memory limit | `1073741824` bytes (1 GiB). |
| Scoring | One ICPC-style subtask containing all test cases, with total score `1.0`. |
| Targets | One `default` target using `hull.problemTarget.common`. |
| Solutions | C++17. |
| Non-solution programs | C++23. |
| Participant visibility | Private, except files participants must receive to solve the problem. |

Do not require the user to provide every field. Generate a missing name, full statement, constraints, solution, standard program, brute-force programs, subtasks, traits, target configuration, tests, or data when enough semantics exist to do so correctly.

## Coordinate Other Skills And Agents

- Use a structured asking skill only for decisions that can change problem semantics, legal answers, scoring intent, or an interaction protocol. Batch related decisions and provide a recommended choice.
- Use brainstorming before inventing or materially changing a problem idea.
- If no solution is supplied, delegate independent solution analysis to a highest-reasoning subagent, then verify the proof and complexity yourself.
- Parallelize independent solution search, adversarial review, and data-pattern analysis when doing so does not create concurrent writes to one workspace.
- Keep every writing task under one writer at a time. Subagents may return analysis but must not modify the shared problem workspace unless explicitly assigned exclusive files.

## Execute The Workflow

Move forward when a phase is coherent. Return to an earlier phase whenever evidence invalidates its assumptions.

### 1. Classify The Starting Point

Identify whether the input is idea-only, a partial problem, an existing problem to reproduce or adapt, or an existing Hull workspace. Inventory supplied facts without demanding absent optional information.

### 2. Resolve The Minimum Contract

Determine the display language, machine identifier, title, task, legal inputs and outputs, constraints, scoring style, limits, and requested targets. Apply defaults for omitted ordinary choices.

For idea-only input, first make the core task precise and ensure it has an intended algorithmic distinction. For partial input, preserve settled semantics and fill gaps. For an existing task, preserve its mathematical contract unless the user requests a semantic change.

### 3. Inspect Or Initialize The Workspace

Apply [hull-configuration.md](references/hull-configuration.md) to inspect or initialize the selected working directory.

Read the workspace's own conventions and dependencies. Follow the documentation-discovery procedure in [hull-configuration.md](references/hull-configuration.md). Use existing tools first. A missing one-off tool may be obtained with `nix shell`; create or modify project dependencies directly, but ask before permanent system or user-profile installation.

### 4. Establish The Problem Contract

Apply [problem-design-and-statement.md](references/problem-design-and-statement.md) to settle the complete mathematical contract, intended algorithmic distinction, constraints, and every requested statement language.

### 5. Implement Solutions

When the user provides an algorithm but no standard program, implement it. When the user provides a standard program but no prose solution, derive and verify its algorithm, proof, and complexity. When neither is supplied, design both.

Apply [programs-and-cplib.md](references/programs-and-cplib.md) to implement and explain the required correct and suboptimal solution family.

### 6. Implement Components And Configuration

Implement the validator, generator, required judging components, concise component tests, documents, groups, traits, subtasks, limits, and requested targets. Apply [programs-and-cplib.md](references/programs-and-cplib.md) to component behavior and [hull-configuration.md](references/hull-configuration.md) to registration and packaging.

Finish this phase with one coherent configuration ready to generate and validate data.

### 7. Construct Strong Data

Apply [data-subtasks-and-limits.md](references/data-subtasks-and-limits.md) to design generator modes, directed cases, groups, traits, subtasks, scores, and selected testcases. Generate expected outputs with the main correct solution.

### 8. Calibrate In A Feedback Loop

Run the solution, data, and performance checks in [verification.md](references/verification.md), then apply the calibration rules in [data-subtasks-and-limits.md](references/data-subtasks-and-limits.md). When evidence invalidates an earlier assumption, return to the earliest affected phase and repeat all downstream checks.

### 9. Build And Verify

Apply [verification.md](references/verification.md) and resolve every unexpected result before delivery.

### 10. Deliver

Provide the completion evidence listed in [verification.md](references/verification.md). State any unresolved risk explicitly and do not claim completion while a required check remains unverified.
