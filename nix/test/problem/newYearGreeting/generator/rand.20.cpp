#include <cstdint>
#include <iostream>
#include <set>

#include "cplib.hpp"
#include "problem.20.hpp"

CPLIB_REGISTER_GENERATOR(gen, args, k_max = Var<cplib::var::u32>("k-max", CNT - 1, 4294967295),
                         salt = Var<cplib::var::String>("salt"));

void generator_main() {
  using args::k_max;

  std::set<uint32_t> S;

  std::cout << "encode\n";

  while (S.size() != CNT) {
    uint32_t x = gen.rnd.next<uint32_t>(0, k_max);
    if (S.contains(x)) continue;
    uint32_t y = gen.rnd.next<uint32_t>(0, CNT - 1);
    S.insert(x);
    std::cout << x << ' ' << y << '\n';
  }

  gen.quit_ok();
}
