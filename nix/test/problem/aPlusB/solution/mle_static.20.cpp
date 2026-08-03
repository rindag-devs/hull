#include <cstring>
#include <iostream>

constexpr int N = 1e8 + 9;
int a[N];

auto main() -> int {
  memset(a, 0x3f, sizeof a);
  unsigned int a, b;
  std::cin >> a >> b;
  while (true) {
    a += b;
    a *= b;
    a %= static_cast<int>(1e9) + 7;
  }
  return 0;
}
