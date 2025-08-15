#include <iostream>
#include <vector>

volatile unsigned long long result = 0;

auto main() -> int {
  std::ios_base::sync_with_stdio(false);
  std::cin.tie(NULL);
  unsigned int a, b;
  std::cin >> a >> b;
  std::vector<unsigned int> vec(1000, a);
  while (true) {
    for (unsigned int i = 0; i < vec.size(); ++i) {
      vec[i] = (vec[i] * (b + i)) % (1000000007) + (result & 1);
    }
    result += vec[0];
  }
  return 0;
}
