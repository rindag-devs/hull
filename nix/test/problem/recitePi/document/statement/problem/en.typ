#let description = [
  *This is an answer-only problem.*

  You are asked to output the decimal representation of $pi$ with as many digits as possible. Your output must have at least $1$ and at most $10^5$ digits after the decimal point.
]

#let input = none

#let output = [
  A single line containing a decimal number, representing the value of $pi$. It must start with `3.`.
]

#let notes = [
  Let your submitted answer be $S_p$ and the judge's answer be $S_j$. The scoring system will compare $S_p$ and $S_j$ character by character from the beginning.

  Let $d$ be the number of *consecutively correct* digits you provide, starting from the first digit after the decimal point. (This means the first $d+2$ characters of your answer match the judge's answer, but the $(d+3)$-th character does not, or one of the strings ends).

  Your score will be $d / (10^5)$ of the full score.

  For example, if the standard value of $pi$ is `3.14159...`:
  - If you submit `3.142`, the first error occurs at the 3rd decimal place (`2` vs `1`). Thus, you have $d=2$ consecutively correct digits. Your score will be $2 / 10^5$ of the full score.
  - If you submit `3.141`, you have $d=3$ consecutively correct digits, and your score will be $3 / 10^5$ of the full score.
]
