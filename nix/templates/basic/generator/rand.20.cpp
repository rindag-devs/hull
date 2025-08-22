#include <iostream>

#include "cplib.hpp"

CPLIB_REGISTER_GENERATOR(gen, args,
                         n_min = Var<cplib::var::i32>("n-min", -1000, 1000),
                         n_max = Var<cplib::var::i32>("n-max", -1000, 1000),
                         salt = Var<cplib::var::String>("salt"));

void generator_main() {
  using args::n_min, args::n_max;

  if (n_min > n_max) cplib::panic("n_min must be <= n_max");

  int a = gen.rnd.next(n_min, n_max);
  int b = gen.rnd.next(n_min, n_max);

  std::cout << a << ' ' << b << '\n';

  gen.quit_ok();
}
