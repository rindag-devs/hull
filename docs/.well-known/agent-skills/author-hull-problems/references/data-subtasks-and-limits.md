# Data, Subtasks, And Limits

## Contents

- Coverage model
- Directed construction families
- Samples and groups
- Subtasks and traits
- Scores and test counts
- Solution predictions
- Time limits
- Memory limits

## Coverage Model

Start from the algorithms and failure modes, not from a desired number of cases. List every dimension that can change control flow or complexity: each size variable, value range, parity, threshold, density, order, repetition pattern, graph or tree shape, query distribution, and aggregate constraint.

Give generator args independent modes for these dimensions. Form Cartesian products of modes where interactions matter. Select representative combinations deliberately, because a random sample from each dimension does not cover their interactions.

For every intended-solution branch, include cases on both sides of its threshold and at the threshold. Cover every special-case boundary. When increasing a size variable only strengthens a case without changing its nature, place it at or immediately below the applicable upper bound rather than wasting cases on weak middle sizes.

For multi-test input with a bounded total, include distributions such as many minimum-size tests, many similarly large tests when legal, one maximum-size test plus many small tests, and mixtures that hit both the per-test and total bounds.

## Directed Construction Families

Adapt constructions to the actual problem; do not add irrelevant stock cases. Common useful families include:

- Intervals of minimum length, single points, maximum length, and the whole sequence.
- Values with many repeated prime factors, such as powers of two.
- Values with many distinct prime factors, such as products of small primes.
- Highly composite values when divisor count matters.
- Trees that are chains, stars, complete binary trees, binary trees whose nodes are replaced by chains, a star with a long arm, and a chain with attached leaves.
- The recursively unbalanced tree $T_d$, with height measured as the number of vertices on a longest root-to-leaf path: $T_1$ is one vertex; for $d > 1$, create a new root, make its left subtree a path on $d - 1$ vertices whose endpoint adjacent to the root is the left child, and make its right subtree a copy of $T_(d - 1)$ whose root is the right child.
- Sorted, reverse-sorted, constant, alternating, clustered, periodic, sparse, and dense sequences or structures when relevant.

Add cases targeting plausible overflow, off-by-one, wrong tie handling, accidental quadratic behavior, incorrect greedy choices, invalid monotonic assumptions, hash collisions when realistically relevant, and excessive memory use.

## Samples And Groups

Samples are part of the public contract. Keep them small enough to understand, cover distinct behavior, and ensure their explanations match every language version.

Both `sample` and `sampleLarge` are sample testcase groups. Cases in `sample` are automatically embedded in generated statements. Cases in `sampleLarge` are distributed as samples but not embedded in the statement; use it for a sample that is useful to provide but too large to display inline.

Use generated inputs by default. Fixed external input files are acceptable for tiny hand-written samples or an exceptional construction that is clearer and safer as a literal file.

## Subtasks And Traits

Add partial scoring only when the user requests it or it materially improves the problem; otherwise use the default in `SKILL.md`.

For size-based partial scoring, usually provide several bounds corresponding to meaningful complexity classes. Even if no implementation is known for one intermediate class, consider whether that bound gives a fair and useful progression. A half-maximum size subtask can reduce constant-factor pressure, but include it only when it has a clear role.

Use special-property subtasks only when the property supports a meaningful solution or guides thinking toward the intended solution. Do not add a property simply because the generator can produce it, and avoid properties that encourage an unrelated dead end.

Define subtask membership through precise validator-emitted traits. Trait hints are assertions to check against validation, not the source of subtask truth.

## Scores And Test Counts

Allocate subtask scores primarily by difficulty. Give somewhat more weight to a subtask that provides useful insight toward the intended solution. Do not turn this guidance into a mechanical formula.

For a single-subtask ICPC-style problem, roughly 20 to 100 testcases is often appropriate. An IOI-style problem with many subtasks may need hundreds or thousands. These are non-binding ranges: use the smallest set that provides strong coverage, considering problem complexity, number of subtasks, runtime cost, and distinct generation families.

## Solution Predictions

Assign expected outcomes for the main correct solution, pure brute force, intermediate solutions, and realistic wrong solutions. Predictions should describe intentional subtask behavior, including accepted, time-limited, memory-limited, or wrong-answer outcomes as appropriate.

If measured outcomes disagree with predictions, do not mechanically edit the prediction. Investigate whether the implementation is wrong, a testcase has unexpected traits, a subtask is poorly designed, data is weak, limits are wrong, or the proposed complexity distinction does not exist. Change the underlying design when it is the cause.

## Time Limits

Hull measures execution in ticks. For rough initial conversion on modern computers, treat one millisecond of a traditional limit as approximately `10000000` Hull Wasm ticks, then calibrate from measurements.

Choose the largest limit that still rejects unintended approaches. Measure the main correct solution on representative worst cases and give it at least a 1.5 times margin. If the best non-correct approach is more than eight times slower, a margin near two times is reasonable. Account for legitimate variation and all intended languages or implementations relevant to the problem.

Do not tighten a limit merely to compensate for weak data. If correct and incorrect approaches cannot be separated, first reconsider data ranges, generated structures, algorithmic assumptions, subtasks, or the problem contract. Increasing bounds and limits together can be appropriate when it creates a robust complexity separation.

## Memory Limits

Hull's `problem.nix` memory limit is measured in bytes.

Set memory generously unless reducing asymptotic memory is itself a worthwhile part of the task. Data-structure-heavy problems often need substantial headroom. If a high-memory approach is intentionally excluded because the lower-memory idea is meaningful, measure peak use and consider a looser partial-scoring subtask rather than relying on a brittle threshold.
