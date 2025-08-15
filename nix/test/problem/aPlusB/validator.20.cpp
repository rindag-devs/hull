#include <cstdint>
#include <tuple>
#include <vector>

#include "cplib.hpp"

using cplib::var::i32;
using cplib::var::Reader;

struct Input {
  int32_t n, m;

  static auto read(Reader& in) -> Input {
    int32_t n, m;
    std::tie(n, std::ignore, m, std::ignore) =
        in(i32("n", -1000, 1000), cplib::var::space, i32("m", -1000, 1000), cplib::var::eoln);
    return {.n = n, .m = m};
  }
};

auto traits(const Input& input) -> std::vector<cplib::validator::Trait> {
  return {
      {"n_positive", [&]() { return input.n > 0; }},
      {"m_positive", [&]() { return input.m > 0; }},
  };
}

CPLIB_REGISTER_VALIDATOR(Input, traits);
