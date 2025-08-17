#include <cstdint>
#include <tuple>
#include <vector>

#include "cplib.hpp"

using cplib::var::i32;
using cplib::var::Reader;

struct Input {
  int32_t a, b;

  static auto read(Reader& in) -> Input {
    int32_t n, m;
    std::tie(n, std::ignore, m, std::ignore) =
        in(i32("a", -1000, 1000), cplib::var::space, i32("b", -1000, 1000), cplib::var::eoln);
    return {.a = n, .b = m};
  }
};

auto traits(const Input& input) -> std::vector<cplib::validator::Trait> {
  return {
      {"a_positive", [&]() { return input.a > 0; }},
      {"b_positive", [&]() { return input.b > 0; }},
  };
}

CPLIB_REGISTER_VALIDATOR(Input, traits);
