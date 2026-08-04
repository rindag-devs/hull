# Data, Subtasks, And Limits

## Contents

- Coverage model
- Directed construction families
- Sample data
- Subtasks and traits
- Scores and test counts
- Solution predictions
- Time limits
- Memory limits
- File-size limits

## Coverage Model

Start from the algorithms and failure modes, not from a desired number of cases. List every dimension that can change control flow or complexity:

- Each size variable
- Value range
- Parity
- Threshold
- Density
- Order
- Repetition pattern
- Graph or tree shape
- Query distribution
- Aggregate constraint

Give generator args independent modes for these dimensions. Form Cartesian products of modes where interactions matter. Select representative combinations deliberately. A random sample from each dimension does not cover their interactions.

For every intended-solution branch, include cases on both sides of its threshold and at the threshold. Cover every special-case boundary. Do not waste cases on weak middle sizes. When increasing a size variable only strengthens a case, use a size at or just below the applicable upper bound.

For multi-test input with a bounded total, include these distributions:

- Many minimum-size tests
- Many similarly large tests, when legal
- One maximum-size test plus many small tests
- Mixtures that hit both the per-test and total bounds

## Directed Construction Families

Adapt constructions to the actual problem. Do not add irrelevant stock cases. Common useful families include:

- Intervals of minimum length, single points, maximum length, and the whole sequence.
- Values with many repeated prime factors, such as powers of two.
- Values with many distinct prime factors, such as products of small primes.
- Highly composite values when divisor count matters.
- Trees that are chains, stars, complete binary trees, binary trees whose nodes are replaced by chains, a star with a long arm, and a chain with attached leaves.
- The recursively unbalanced tree $T_d$, with height measured as the number of vertices on a longest root-to-leaf path. $T_1$ is one vertex. For $d > 1$, create a new root. Make its left subtree a path on $d - 1$ vertices. The path endpoint adjacent to the root is the left child. Make its right subtree a copy of $T_(d - 1)$ whose root is the right child.
- Sorted, reverse-sorted, constant, alternating, clustered, periodic, sparse, and dense sequences or structures when relevant.

Add cases targeting plausible overflow, off-by-one, wrong tie handling, accidental quadratic behavior, and incorrect greedy choices. Add cases targeting invalid monotonic assumptions, realistic hash collisions, and excessive memory use.

## Sample Data

An ICPC-style problem normally does not need large samples. For an OI-style problem, normally select one purely random generated testcase from each data-size tier as a large sample. If random data has an extremely unrepresentative property, choose a representative directed testcase instead. Such a property can be every answer being no solution. If neither choice helps contestants, omit the large sample.

Use generated inputs by default. You can use fixed external input files for tiny hand-written samples. Use them for an exceptional construction that is clearer and safer as a literal file.

## Subtasks And Traits

Add partial scoring only when the user requests it or it materially improves the problem. Otherwise, use the default in `SKILL.md`.

For size-based partial scoring, usually provide several bounds corresponding to meaningful complexity classes. Even if no implementation is known for one intermediate class, consider whether that bound gives a fair and useful progression. A half-maximum size subtask can reduce constant-factor pressure. Include it only when it has a clear role.

Use special-property subtasks only when the property supports a meaningful solution or guides thinking toward the intended solution. Do not add a property simply because the generator can produce it. Avoid properties that encourage an unrelated dead end.

Define subtask membership through precise validator-emitted traits. Trait hints are assertions that validation must satisfy. They are not the source of subtask truth.

Use concise affirmative trait names. Prefer exact names such as `n_le_1000`, `a_ge_100`, `a_mod_2_eq_0`, `is_tree`, or `n_is_odd`. Avoid vague names such as `is_small` and negative names containing `not`. Represent the negative case through an affirmative trait with value `false`.

## Scores And Test Counts

Allocate subtask scores primarily by difficulty. Give somewhat more weight to a subtask that provides useful insight toward the intended solution. Do not turn this guidance into a mechanical formula.

For a single-subtask ICPC-style problem, roughly 20 to 100 testcases is often appropriate. An IOI-style problem with many subtasks can need hundreds or thousands. These ranges are not binding. Use the smallest set that provides strong coverage. Consider problem complexity, number of subtasks, runtime cost, and distinct generation families.

## Solution Predictions

Design expected outcomes for the main correct solution, pure brute force, intermediate solutions, and realistic wrong solutions. Predict each solution's behavior per subtask before you measure it. Register predictions using the statuses defined in [hull-configuration.md](hull-configuration.md).

## Time Limits

Hull measures execution in ticks. For rough initial conversion on modern computers, treat one millisecond of a traditional limit as approximately `10000000` Hull Wasm ticks. Then calibrate from measurements.

Choose a limit that safely admits intended approaches and rejects unintended approaches under the calibration rules in [verification.md](verification.md).

Do not tighten a limit merely to compensate for weak data. If correct and incorrect approaches cannot be separated, reconsider data ranges, generated structures, algorithmic assumptions, subtasks, or the problem contract. Increasing bounds and limits together can be appropriate when it creates a robust complexity separation.

## Memory Limits

Set memory generously unless reducing asymptotic memory is itself a worthwhile part of the task. Data-structure-heavy problems often need substantial headroom. If a high-memory approach is intentionally excluded, consider a looser partial-scoring subtask. This applies when the lower-memory idea is meaningful. Do not rely on a brittle threshold. Calibrate the final value under [verification.md](verification.md).

## File-Size Limits

Do not override the file-size limit unless the problem has unusual file requirements. When an override is needed, derive it from legitimate worst-case files and streams. Calibrate it under [verification.md](verification.md). If overflow is intentional, predict the configured file-error status.
