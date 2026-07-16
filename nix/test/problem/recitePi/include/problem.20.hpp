#pragma once

#include <algorithm>
#include <cstddef>
#include <format>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

#include "cplib.hpp"

constexpr std::size_t N_DIGITS = 100000;

struct Input {
  std::string s;

  static auto read(cplib::var::Reader &in) -> Input {
    std::string s;
    std::tie(s, std::ignore) =
        in(cplib::var::String("s", cplib::Pattern("3\\.[0-9]+")), cplib::var::eoln);
    if (s.size() != N_DIGITS + 2) {
      const auto digits = s.size() >= 2 ? s.size() - 2 : 0;
      in.fail(std::format("Expected {} digits after point, found {}", N_DIGITS, digits));
    }
    return {std::move(s)};
  }
};

struct Output {
  std::string s;

  static auto read(cplib::var::Reader &in, const Input &) -> Output {
    auto s = in.read(
        cplib::var::String("s", cplib::var::String::Mode::LINE, cplib::Pattern("3\\.[0-9]+")));
    return {std::move(s)};
  }

  static auto evaluate(cplib::evaluate::Evaluator &, const Output &pans, const Output &jans,
                       const Input &) -> cplib::evaluate::Result {
    auto res = cplib::evaluate::Result::ac();
    std::size_t min_length = std::min(pans.s.size(), jans.s.size());
    std::size_t n_correct_digit = 0;
    for (std::size_t i = 0; i < min_length; ++i) {
      if (pans.s[i] == jans.s[i]) {
        n_correct_digit = i + 1;
      } else {
        break;
      }
    }
    if (n_correct_digit < jans.s.size()) {
      n_correct_digit = n_correct_digit >= 2 ? n_correct_digit - 2 : 0;
      std::size_t max_digit = jans.s.size() - 2;
      res &= cplib::evaluate::Result::pc(
          static_cast<double>(n_correct_digit) / static_cast<double>(max_digit),
          std::format("Correct digit {} / {}", n_correct_digit, max_digit));
    }
    return res;
  }
};

inline auto traits(const Input &) -> std::vector<cplib::validator::Trait> { return {}; }
