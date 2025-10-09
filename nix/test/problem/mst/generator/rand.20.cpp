#include <algorithm>
#include <iostream>

#include "cplib.hpp"

using cplib::var::i32, cplib::panic;

CPLIB_REGISTER_GENERATOR(gen, args,                          //
                         T = Var<i32>("T", 1, 5),            //
                         n_min = Var<i32>("n-min", 1, 1e6),  //
                         n_max = Var<i32>("n-max", 1, 1e6),  //
                         m_min = Var<i32>("m-min", 1, 1e6),  //
                         m_max = Var<i32>("m-max", 1, 1e6),  //
                         w_min = Var<i32>("w-min", 0, 1e9),  //
                         w_max = Var<i32>("w-max", 0, 1e9),  //
                         salt = Var<cplib::var::String>("salt"));

void generator_main() {
  using args::m_min, args::m_max;
  using args::n_min, args::n_max;
  using args::T;
  using args::w_min, args::w_max;

  if (n_min > n_max) panic("n_min must be <= n_max");
  if (m_min > m_max) panic("m_min must be <= m_max");
  if (w_min > w_max) panic("w_min must be <= w_max");

  std::cout << T << '\n';

  for (int t = 1; t <= T; ++t) {
    int n = gen.rnd.next(n_max, n_max);

    int final_m_min = std::max(m_min, n - 1);
    if (final_m_min > m_max) panic("final_m_min must be <= m_max");

    int m = gen.rnd.next(final_m_min, m_max);

    std::cout << n << ' ' << m << '\n';

    for (int i = 2; i <= n; ++i) {
      std::cout << gen.rnd.next(1, i - 1) << ' ' << i << ' ' << gen.rnd.next(w_min, w_max) << '\n';
    }

    for (int i = n; i <= m; ++i) {
      std::cout << gen.rnd.next(1, n) << ' ' << gen.rnd.next(1, n) << ' '
                << gen.rnd.next(w_min, w_max) << '\n';
    }
  }

  gen.quit_ok();
}
