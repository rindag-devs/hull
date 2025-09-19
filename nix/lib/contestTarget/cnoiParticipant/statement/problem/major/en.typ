#let description = [
  *For a sequence, the majority element of it is defined as the number whose occurrence is strictly more than half the size of the sequence. This is different from the mode of a sequence. Please refer to this definition in this problem.*

  You're given $n$ positive integer sequences of varying length, labeled by $1 ~ n$. The initial sequence may be empty. These $n$ sequences exist while sequences labelled by other numbers are deemed non-existent.

  There are $q$ operations of following types:

  - $1 " " x " "y$: Insert number $y$ at the end of sequence $x$. It is guaranteed that sequence $x$ exists, and $1 <= x,y <= n+q$.
  - $2 " " x$: Remove the last number from sequence $x$. It is guaranteed that sequence $x$ exists, is non-empty, and $1 <= x <= n+q$.
  - $3 " " m " " x_1 " " x_2 " " dots " " x_m$: Concatenate sequences $x_1,x_2,dots,x_m$ in order into a new sequence and query its majority element. If no such number exists, return $-1$. It is guaranteed that sequence $x_i$ still exists for any $1 <= i <= m$, $1 <= x_i <= n+q$, and the resulting sequence is non-empty. *Note: it is not guaranteed that $bold(x_1\, x_2\, dots\, x_m)$ are distinct, and the combining operation in this query has no effect on following operations.*
  - $4 " " x_1 " " x_2 " " x_3$: Create a new sequence $x_3$ as the result of successively inserting numbers in sequence $x_2$ to the end of sequence $x_1$, then remove the sequences corresponding to numbers $x_1,x_2$. At this time sequence $x_3$ is deemed existent, sequence $x_1,x_2$ don't exist and won't be used in following operations. It is guaranteed that $1 <= x_1,x_2,x_3 <= n+q$, $x_1 != x_2$, sequences $x_1,x_2$ exist before this operation, and sequence $x_3$ is not used by any preceding operations.
]

#let input = [
  The first line of input contains two integers $n$ and $q$, each indicating the number of sequences and operations. It is guaranteed that $n <= 5 times 10^5$, $q <= 5 times 10^5$.

  For the following $n$ lines, the $i$th line corresponds to sequence $i$. Each line begins with a non-negative integer $l_i$ indicating the number count of the initial $i$th sequence. Following are $l_i$ nonnegative numbers $a_(i,j)$ representing the numbers in the sequence in order. Suppose $C_l = sum l_i$ is the sum of length of the inputted sequences, then it is guaranteed that $C_l <= 5 times 10^5$, $a_(i,j) <= n+q$.

  Each of the following $Q$ lines consists of several integers representing an operation, formatted as stated in the description.

  Suppose $C_m = sum m$ is the sum of number of sequences to be concatenated in all type $3$ operations, then it is guaranteed that $C_m <= 5 times 10^5$.
]

#let output = [
  For each query, output a line of one integer indicating the corresponding answer.
]

#let notes = [
  For all the tests, $1 <= n,q,C_m,C_l <= 5 times 10^5$.
]
