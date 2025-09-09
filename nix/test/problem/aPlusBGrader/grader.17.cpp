#include <cstdint>
#include <ios>
#include <iostream>

#include "add.h"

auto main() -> int {
  std::ios::sync_with_stdio(false);
  std::cin.tie(nullptr);
  std::cout.tie(nullptr);
  int32_t a, b;
  std::cin >> a >> b;
  int32_t c = add(a, b);
  std::cout << c << '\n';
}
