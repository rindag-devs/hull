#include <cstdint>
#include <tuple>

#include "cplib.hpp"

CPLIB_REGISTER_VALIDATOR(val);

void validator_main() {
  using cplib::var::i32, cplib::var::space, cplib::var::eoln;

  int32_t n, m;
  val.traits({
      {"n_positive", [&]() { return n > 0; }},
      {"m_positive", [&]() { return m > 0; }},
  });

  std::tie(n, std::ignore, m, std::ignore) =
      val.inf(i32("n", -1000, 1000), space, i32("m", -1000, 1000), eoln);

  val.quit_valid();
}
