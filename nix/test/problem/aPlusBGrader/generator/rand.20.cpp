#include <iostream>

#include "cplib.hpp"

using cplib::var::i32, cplib::panic;

CPLIB_REGISTER_GENERATOR(gen, args,                               //
                         n_min = Var<i32>("n-min", -1000, 1000),  //
                         n_max = Var<i32>("n-max", -1000, 1000),  //
                         same = Flag("same"));

void generator_main() {
  using args::n_min, args::n_max, args::same;

  if (n_min > n_max) panic("n_min must be <= n_max");

  int a = gen.rnd.next(n_min, n_max);
  int b = same ? a : gen.rnd.next(n_min, n_max);

  std::cout << a << ' ' << b << '\n';

  gen.quit_ok();
}
