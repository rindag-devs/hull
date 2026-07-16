#include <cstdint>
#include <print>
#include <set>

#include "cplib.hpp"
#include "problem.23.hpp"

CPLIB_REGISTER_GENERATOR(gen, args, k_max = Var<cplib::var::u32>("k-max", CNT - 1, 4294967295),
                         salt = Var<cplib::var::String>("salt"));

void generator_main() {
  using args::k_max;

  std::set<std::uint32_t> keys;

  std::println("encode");

  while (keys.size() != CNT) {
    auto x = gen.rnd.next<std::uint32_t>(0, k_max);
    if (!keys.insert(x).second) continue;
    auto y = gen.rnd.next<std::uint32_t>(0, CNT - 1);
    std::println("{} {}", x, y);
  }

  gen.quit_ok();
}
