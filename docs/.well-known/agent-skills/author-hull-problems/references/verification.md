# Verification

## Contents

- Verification order
- Contract consistency
- Component checks
- Solution and data checks
- Reproducibility
- Performance calibration
- Statements and samples
- Targets and packages
- Differential diagnosis
- Completion evidence

## Verification Order

Verify from the smallest semantic boundary outward:

1. Format and compile individual sources.
2. Run concise validator, checker, and interactor component tests.
3. Generate data twice where reproducibility is relevant and compare bytes.
4. Validate all generated and fixed inputs and inspect traits.
5. Produce expected outputs with the main correct solution.
6. Run all configured solutions and evaluate their predictions.
7. Render and inspect every statement language and sample.
8. Build every requested target and inspect its published artifact.

Use the commands documented by the problem's pinned Hull version. Record exact commands and results.

## Contract Consistency

Audit the statement constraints, validator bounds, generator args, and intended-solution assumptions as four representations of one contract. Compare every variable, character set, precision rule, aggregate limit, structural guarantee, indexing rule, and output condition.

Check that checker behavior exactly matches legal output wording, including tolerance boundaries and extra tokens. Check that subtask traits derive from validator-observed properties and that generator invocations satisfy their declared group.

## Component Checks

Keep component tests short and attack a concrete realistic defect. At minimum, select tests relevant to the problem from these categories:

- Smallest valid input and a representative maximum-bound form.
- One token just below or above a bound.
- Missing, malformed, or trailing tokens.
- Violated aggregate or structural guarantees.
- A valid non-unique construction unlike the jury output.
- An invalid construction that superficially resembles a valid one.
- Floating tolerance just inside and outside the boundary, plus NaN or infinity rejection.
- Interactive query-limit, malformed-message, flush, and termination behavior.

Do not add all categories mechanically. Each test must correspond to a failure the component could plausibly have.

## Solution And Data Checks

Run the main correct solution on every testcase. Independently verify small cases against a pure brute force where available. Inspect every algorithm branch and every directed data family.

Run pure brute-force, intermediate-complexity, and plausible wrong solutions across all groups. Confirm outcomes agree with the intended subtask design. Apply the diagnosis rules in [data-subtasks-and-limits.md](data-subtasks-and-limits.md) to every mismatch.

## Reproducibility

Run representative generator commands at least twice with exactly identical argument sequences and compare output bytes. Also verify that the same semantic arguments written in a different order are not accidentally treated as interchangeable if CPLib derives randomness from the raw command line.

Search all authoring programs for nondeterministic or implementation-dependent APIs and inspect whether output depends on unordered iteration, locale, time, uninitialized storage, or host state.

## Performance Calibration

Measure the main correct solution and best result-correct suboptimal implementation on the representative worst cases selected by the data plan. Record tick and memory results rather than relying on aggregate build duration.

Verify that measured limits satisfy the margins in [data-subtasks-and-limits.md](data-subtasks-and-limits.md), intended approaches remain safe, and approaches meant to fail remain rejected.

## Statements And Samples

Build and visually inspect every requested statement language. Check block spacing, list continuity, math rendering, code literals, Chinese punctuation, English ASCII usage, and absence of excessive emphasis.

For each sample, run the validator, main solution, and checker. Verify the displayed input/output, explanation, and configured publication behavior.

Compare multilingual statements sentence by sentence for matching definitions, constraints, notes, and output rules.

## Targets And Packages

Build every user-requested target. Inspect the resulting package or directory through that target's documented consumer path, not only by checking that a derivation exists.

Confirm that participant-facing output matches the configured visibility and contains every required statement or interface. Verify each target independently and do not infer one platform's success from another's build.

## Differential Diagnosis

Do not make differential testing a routine gate. Use it when an unexpected result is reproducible and comparing outputs will help localize the defect.

Compare the main correct solution against a program that computes correct answers but has unsuitable complexity for full constraints. Restrict generated cases to sizes both can finish. Minimize a mismatch before changing code. Do not use a second implementation that copies the same algorithm and likely shares the same defect.

## Completion Evidence

Before declaring completion, provide:

- The final problem contract and intended complexity.
- Subtasks, traits, scores, and testcase-group rationale.
- Measured time and memory evidence supporting limits.
- Component, solution-prediction, statement, and target verification commands with passing results.
- The generated artifacts and their locations.
- Any unresolved limitation or unverified environment, stated explicitly.

Do not claim completion if any requested target, language, component, sample, prediction, or package has not been exercised.
