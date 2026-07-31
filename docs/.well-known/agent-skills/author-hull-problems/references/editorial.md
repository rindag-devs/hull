# Editorial

## Contents

- Document layout and language
- Problem interpretation
- Solution explanation
- Correctness proof
- Complexity analysis
- Implementation references
- ICPC-style editorials
- Partial-scoring editorials

## Document Layout And Language

By default, write one editorial in each statement language. Store each editorial as `document/editorial/<language-code>.typ`, using the language identified by `<language-code>`. Follow a user-specified editorial language set when it differs from the statement languages.

Follow the statement's language, formatting, typography, and multilingual rules from [problem-design-and-statement.md](problem-design-and-statement.md). Use exactly the same terms for problem-defined concepts in the statement and editorial. Do not rename one concept between documents, such as using `cost` in the statement and `price` in the editorial.

Keep all language versions semantically equivalent. Preserve the same algorithms, claims, correctness arguments, complexity bounds, subtask expectations, and qualifications in every version.

Use standard Typst formatting, functions, and styles. Do not define decorative styles or use third-party Typst packages unless the editorial has a concrete requirement that standard Typst cannot meet.

Use exactly one level-one heading: `= Editorial`, `= 题解`, or the equivalent title in the editorial's language.

## Problem Interpretation

Begin by interpreting the problem. State its central idea and computational objective in concise, condensed language so that the reader can identify the task immediately.

Do not copy the statement or paraphrase it section by section. The interpretation should communicate the problem's purpose and program goal at a glance while retaining every fact needed to understand the subsequent solution.

## Solution Explanation

Explain the overall solution and the concrete procedure used to obtain the answer. Describe the problem-specific reasoning, algorithm, data structure, transformation, maintained state, recurrence, invariant, construction, or operations that make the solution applicable to this problem.

Assume that the reader understands the principles and standard use of the required algorithms and data structures. Unless the problem is a template task for that technique, do not teach generic material. For example, a segment-tree editorial may explain what information each node maintains, how tags and merge operations are designed, and which operations this problem needs; it must not teach what a segment tree is or describe generic construction, update, push-up, or push-down procedures.

## Correctness Proof

Prove that the algorithm produces the correct result for every legal input. Use the problem-specific invariant, equivalence, recurrence, exchange argument, construction, or other decisive reasoning on which correctness depends.

Distinguish a rigorous correctness guarantee from a heuristic, randomized assumption, or empirical observation whenever that distinction affects validity. Do not present experimental evidence as a correctness proof.

If correctness follows immediately from the stated procedure and standard algorithmic results, state the correctness basis without expanding it into a lengthy proof. A proof may cite a standard result without reproducing a derivation whose difficulty substantially exceeds the problem, such as the inverse-Ackermann amortized bound for disjoint-set union.

## Complexity Analysis

State the final program's time and space complexity in the relevant variables. Prove the time-complexity bound of the algorithm.

Provide a rigorous derivation for every nontrivial time bound and state every required assumption. This includes, but is not limited to, deterministic bounds that require a non-obvious counting argument, expected complexity, amortized analysis, and bounds that depend on a random property of the input.

For an immediate time or space bound that follows directly from the procedure, visibly nested loops, or a standard algorithmic result, state the bound without reproducing a lengthy derivation. Even when detailed proof is omitted, state the correctness basis and the final time and space bounds.

## Implementation References

Do not paste or embed complete solution source code into an editorial. When implementation details need a concrete reference, identify the corresponding file in the `solution` directory, such as `solution/std.17.cpp`.

Keep implementation references consistent with the algorithms explained in the editorial. Do not refer to deliberately wrong solutions as if they were implementations of an editorial algorithm.

## ICPC-Style Editorials

For a problem with one subtask and no partial scoring, explain only the intended full solution. Do not use level-two or level-three headings. Under the single level-one heading, present the problem interpretation, overall solution, correctness proof or correctness basis, and complexity analysis in a short sequence of paragraphs.

## Partial-Scoring Editorials

For an IOI-style or other partial-scoring problem, first define the notation shared by all approaches and give the common problem interpretation. Explain every intended correct approach that targets a distinct subtask set or score tier, including the full solution and intended brute-force or intermediate approaches. Do not include deliberately wrong solutions used only to test the data.

Include an approach only when it contributes a different complexity, correctness argument, implementation tradeoff, or subtask outcome. Omit cosmetic variants and approaches that do not represent an intended score path.

Use level-two headings `== Algorithm 0`, `== Algorithm 1`, and so on, numbered from zero, or exact equivalents in the editorial's language. Under each heading, explain that algorithm's overall approach and concrete procedure, prove its correctness or state the applicable standard correctness basis, and give its own time and space complexity with the time-bound reasoning required by [Complexity Analysis](#complexity-analysis).

End each algorithm section with a standalone paragraph stating its expected subtask outcome. Use zero-indexed subtask numbers and one of these forms:

- Chinese: `预期通过 subtask 0、1、3．`, `预期无法通过任何 subtask．`, or `预期通过所有 subtask．`
- English: `Expected to pass subtasks 0, 1, and 3.`, `Expected to pass no subtasks.`, or `Expected to pass all subtasks.`

If a subtask can award a score strictly between zero and its full score, state the expected score instead of only listing passed subtasks. Use forms such as:

- Chinese: `预期得分：0.123 分．` or `预期 subtask 0 获得 0.1 分，subtask 1、2 获得 0.2 分．`
- English: `Expected score: 0.123 points.` or `Expected to score 0.1 points on subtask 0 and 0.2 points on subtasks 1 and 2.`
