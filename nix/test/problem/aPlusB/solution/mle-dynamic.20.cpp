#include <iostream>
#include <vector>

volatile unsigned long long sink = 0;

auto main() -> int {
  std::ios_base::sync_with_stdio(false);
  std::cin.tie(NULL);
  unsigned int a, b;
  std::cin >> a >> b;
  std::vector<long long> mem_eater;
  while (true) {
    mem_eater.push_back(a);
    a = (a + b) % (1000000007);
    if (mem_eater.size() % 100000 == 0) {
      sink = a;
    }
  }
  return 0;
}
