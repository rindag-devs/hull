# Problem Design And Statements

## Contents

- Problem contract
- Statement structure
- Input and output completeness
- Mathematical notation
- Floating-point output
- Chinese statements
- Typst structure
- Multilingual statements
- Bilingual reference wording
- Final ambiguity review

## Problem Contract

Define the problem before polishing prose. Record:

- Every object, operation, index base, ordering rule, tie rule, and equality notion.
- The complete legal input set, including cross-variable and aggregate constraints.
- The complete legal output set and how multiple valid answers are judged.
- Whether empty objects are included, whether repetitions are allowed, and whether order matters.
- Numeric domains, overflow-relevant bounds, precision, and finiteness requirements.
- Guarantees such as connectivity, existence of an answer, uniqueness, or acyclicity.

Check that the intended solution is correct for exactly this contract and that every validator rule follows from it. Do not leave semantic facts exclusively in samples, generator behavior, checker code, or an editorial.

## Statement Structure

Use Typst for Hull statements. Write a concise, readable, and formal contest statement. By default, omit story background and any content unrelated to the task itself. Avoid excessive bold, underline, italics, or other emphasis in every language.

Expand a short draft with this logical order:

1. Introduce all objects and definitions needed to understand the task.
2. State the required computation or construction.
3. Give the input format and define every field where it appears.
4. Give the output format and all acceptance conditions.
5. State sample explanations when they add information beyond repeating arithmetic.
6. State subtask or constraint information when applicable.

Make each sentence understandable when read in order. Resolve a necessary question immediately or in the next paragraph, not several sections later. Do not force readers to inspect the input format or samples to infer the task.

Use one term for one concept throughout. Do not alternate between near-synonyms such as "cost" and "price" for the same quantity. Never assign a common term a nonstandard meaning without defining it. Define every concept that a contestant may reasonably not know.

Prevent both contradiction and technically self-consistent misreading, including unlikely literal readings. State orientation, endpoints, inclusivity, indexing, duplicates, and tie behavior whenever omission permits a different valid interpretation.

## Input And Output Completeness

Define every integer, real number, string, character, list length, and repeated block. For each input value, provide both lower and upper bounds or a finite structural bound. Express positivity through a lower bound rather than merely calling a value "positive" or "nonnegative."

For strings, state length bounds and the character set. For real input, state the numeric range and the maximum number of digits after the decimal point. Include the word "integer" rather than saying only "number" when integrality matters.

Place ranges beside the variables they constrain. Give different ranges as separate formulas; combine variables only when their ranges are identical. Explain the meaning of each variable in the input/output section unless the explanation cannot be made short, in which case refer precisely to the problem description.

Repeat a modulus requirement in both the task description and output section. Render literal output strings as inline code, for example `inf`. If any legal answer is accepted, say so explicitly.

For ordinal prose, normally spell out numbers as words rather than digits, except where mathematical indices or clarity favor digits.

## Mathematical Notation

Use concise mathematical variable names, normally single letters in Typst math mode, for mathematical quantities: for example, a graph $G = (V, E)$ with $n$ vertices and $m$ edges. Preserve program identifiers as code when discussing a name that is part of an API or input format.

Use one capitalization consistently: never use both $n$ and $N$ for one variable. Use conventional international notation. Explain uncommon or potentially ambiguous notation. Typeset differential operators upright as $dif$ and typeset Latin-letter constants such as i and e upright in math mode.

When using these concepts, state the distinctions explicitly:

- A substring is contiguous; a subsequence need not be contiguous.
- State whether "all substrings" or "all subsequences" includes the empty one.
- Define exactly what "distinct" means, such as distinct by value, position set, or sequence.

## Floating-Point Output

Never specify floating-point correctness solely as rounding to a fixed number of decimal places. A rounding boundary can otherwise impose an unbounded precision requirement.

Specify a finite tolerance based on the minimum of absolute and relative error, with an explicit threshold and unambiguous behavior for a zero reference value. State the acceptance rule in the output section, for example that an answer is accepted when its absolute or relative error is less than $10^(-6)$. Checker implementation requirements are defined in [programs-and-cplib.md](programs-and-cplib.md).

## Chinese Statements

Follow the Simplified Chinese rules in [Chinese Copywriting Guidelines](https://raw.githubusercontent.com/sparanoid/chinese-copywriting-guidelines/master/README.zh-Hans.md), including spaces around links and Simplified Chinese corner quotes. Additionally:

- Use the full-width full stop `．` for Chinese sentence endings, including list-item endings. Do not use `。` or an ASCII period as a Chinese sentence ending.
- Use `连通`, not `联通`; use `其他`, not `其它`.
- Add appropriate spacing between Chinese and Latin letters, digits, or inline code as required by the cited guidelines.
- Separate different variable ranges with full-width Chinese commas. Variables with identical ranges may share one formula.

Adapt standard input descriptions precisely. Typical patterns include an initial line containing integer counts and their meanings, a following line containing an indexed sequence and its element bounds, repeated lines indexed by $i$, and a separate guarantee for a tree or other global property.

## Typst Structure

Use `-` for unordered lists. In Typst, `+` denotes an ordered list; prefer explicit `1.`, `2.`, `3.` markers for ordered lists.

Do not put blank lines between items in one list. A blank line splits the items into separate lists. End every list item with punctuation and prefer a full stop to a semicolon. Use `.` in English and `．` in Chinese.

Put one blank line between every block element and adjacent content. Block elements include headings such as `= Heading` and `== Heading`, lists, display equations, and fenced code blocks. Do not place a heading, paragraph, display equation, or list directly against another block.

## Multilingual Statements

Make every requested language version independently readable and sentence-for-sentence equivalent. Do not add a constraint, guarantee, note, or acceptance rule to only one language, except for a language-specific clarification that cannot be removed through unambiguous wording.

Use one stable translation for each term throughout. A translated proper noun may include its original form in parentheses. Prefer wording such as horizontal row and vertical column if a translation could reverse conventional row/column meanings.

Keep English statements ASCII-only in ordinary text. Produce non-ASCII mathematical or punctuation symbols through Typst math mode, `#sym.*`, `--`, or `---` when needed.

## Bilingual Reference Wording

Adapt these patterns to the problem rather than copying irrelevant fields. Keep corresponding language versions semantically identical.

### Counts And Parameters

Chinese:

```typst
输入的第一行包含三个整数 $n$, $m$, $k$（$1 <= n, m <= 2 dot 10^5$，$1 <= k <= 100$），其中 $n$ 表示数列的长度，$m$ 表示操作个数，$k$ 的意义见题目描述．
```

English:

```typst
The first line contains three integers $n$, $m$, and $k$ ($1 <= n, m <= 2 dot 10^5$, $1 <= k <= 100$), where $n$ is the sequence length, $m$ is the number of operations, and $k$ is defined in the problem statement.
```

### Sequence

Chinese:

```typst
输入的第二行包含 $n$ 个整数 $a_1, a_2, ... , a_n$（$1 <= a_i <= 10^9$），表示题目给出的数列．
```

English:

```typst
The second line contains $n$ integers $a_1, a_2, ... , a_n$ ($1 <= a_i <= 10^9$), representing the given sequence.
```

### Repeated Operations

Chinese:

```typst
接下来的 $m$ 行中的第 $i$ 行包含两个整数 $l_i$ 和 $r_i$（$1 <= l_i <= r_i <= n$），表示第 $i$ 次操作在区间 $[l_i, r_i]$ 上进行．
```

English:

```typst
The $i$-th of the next $m$ lines contains two integers $l_i$ and $r_i$ ($1 <= l_i <= r_i <= n$), indicating that the $i$-th operation is performed on the interval $[l_i, r_i]$.
```

### Tree Edges And Guarantee

Chinese:

```typst
接下来的 $n - 1$ 行，每行包含两个整数 $u$ 和 $v$（$1 <= u, v <= n$），表示顶点 $u$ 和 $v$ 之间有一条边．

数据保证给出的边构成一棵树．
```

English:

```typst
Each of the next $n - 1$ lines contains two integers $u$ and $v$ ($1 <= u, v <= n$), denoting an edge between vertices $u$ and $v$.

The given edges are guaranteed to form a tree.
```

### Real Input

Chinese:

```typst
输入的第二行包含一个小数点后不超过三位的实数 $x$（$-10^6 <= x <= 10^6$），其意义见题目描述．
```

English:

```typst
The second line contains a real number $x$ with at most three digits after the decimal point ($-10^6 <= x <= 10^6$), as defined in the problem statement.
```

### Floating-Point Output

Chinese:

```typst
输出一个实数．当输出与标准答案之间的绝对误差或相对误差小于 $10^(-6)$ 时，答案视为正确．
```

English:

```typst
Output a real number. The answer is accepted if its absolute or relative error from the jury answer is less than $10^(-6)$.
```

### Constructive Output

Chinese:

```typst
输出的第二行包含 $n$ 个整数，表示构造的一组方案．其中，第 $i$ 个整数表示第 $i$ 张牌的编号．
```

English:

```typst
The second line contains $n$ integers describing a construction. The $i$-th integer is the index of the $i$-th played card.
```

### Multiple Valid Answers

Chinese:

```typst
如果有多组合法答案，可以输出任意一组．
```

English:

```typst
If multiple valid answers exist, output any one of them.
```

### Literal Output And Modulus

Chinese:

```typst
如果不存在合法答案，输出一行字符串 `inf`．否则，输出答案对 $998244353$ 取模后的结果．
```

English:

```typst
If no valid answer exists, output the string `inf` on one line. Otherwise, output the answer modulo $998244353$.
```

## Final Ambiguity Review

Read the statement adversarially from top to bottom without consulting code. For each sentence, ask whether another literal interpretation changes legal inputs or outputs. Fix ambiguity at its first occurrence rather than adding a late note that leaves earlier text misleading.
