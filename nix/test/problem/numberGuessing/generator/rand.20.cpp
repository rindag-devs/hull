#include <iostream>

#include "cplib.hpp"

using cplib::var::i32, cplib::panic;

CPLIB_REGISTER_GENERATOR(gen, args,                          //
                         n_min = Var<i32>("n-min", 1, 1e9),  //
                         n_max = Var<i32>("n-max", 1, 1e9));

void generator_main() {
  using args::n_min, args::n_max;

  if (n_min > n_max) panic("n_min must be <= n_max");

  int n = gen.rnd.next(n_min, n_max);
  int m = gen.rnd.next(1, n);

  std::cout << n << ' ' << m << '\n';

  gen.quit_ok();
}
