#let description = [
  The Ocean Kingdom consists of $n$ islands. To promote trade and tourism, the king plans to build bridges to connect these islands. There are $m$ potential locations where bridges can be built. Each potential bridge connects two islands, $u$ and $v$, and has an associated construction cost, $w$.

  The king wants to select a subset of these bridges to build such that all islands become connected, meaning it's possible to travel from any island to any other using only the newly built bridges.

  Your task is to help the king find a construction plan that minimizes the total cost. You need to report both the minimum total cost and the specific bridges that should be built.
]

#let input = [
  The first line of input contains a single integer $T$, the number of test cases.

  For each test case:

  The first line contains two integers, $n$ and $m$, representing the number of islands and the number of potential bridges, respectively. The islands are numbered from $1$ to $n$.

  The following $m$ lines each describe a potential bridge. The $i$-th of these lines (corresponding to bridge index $i$) contains three integers $u, v, w$, indicating a potential bridge between island $u$ and island $v$ with a construction cost of $w$.
]

#let output = [
  For each test case, output two lines.

  The first line should contain a single integer: the minimum total cost to connect all islands.

  The second line should contain $n-1$ space-separated integers: the 1-based indices of the bridges chosen for the construction plan. The indices correspond to the order of the bridges in the input (from $1$ to $m$).

  If there are multiple plans that result in the same minimum cost, you may output any one of them. The indices on the second line can be printed in any order.
]

#let notes = [
  - $1 <= T <= 5$.
  - $1 <= n, m <= 2 times 10^5$.
  - $1 <= u, v <= n$, $u != v$.
  - $0 <= w <= 10^9$.
  - It is guaranteed that the initial set of potential bridges is sufficient to connect all islands.
]
