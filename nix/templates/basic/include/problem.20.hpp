#pragma once

#include <cstdint>
#include <tuple>
#include <vector>

#include "cplib.hpp"

struct Input {
  std::int32_t a, b;

  static auto read(cplib::var::Reader& in) -> Input {
    std::int32_t a, b;
    std::tie(a, std::ignore, b, std::ignore) =
        in(cplib::var::i32("a", -1000, 1000), cplib::var::space,
           cplib::var::i32("b", -1000, 1000), cplib::var::eoln);
    return {.a = a, .b = b};
  }
};

struct Output {
  std::int32_t ans;

  static auto read(cplib::var::Reader& in, const Input&) -> Output {
    auto ans = in.read(cplib::var::i32("ans"));
    return {ans};
  }

  static auto evaluate(cplib::evaluate::Evaluator& ev, const Output& pans,
                       const Output& jans, const Input&)
      -> cplib::evaluate::Result {
    auto res = cplib::evaluate::Result::ac();
    res &= ev.eq("ans", pans.ans, jans.ans);
    return res;
  }
};

inline auto traits(const Input& input) -> std::vector<cplib::validator::Trait> {
  return {
      {"a_positive", [&]() { return input.a > 0; }},
      {"b_positive", [&]() { return input.b > 0; }},
  };
}
