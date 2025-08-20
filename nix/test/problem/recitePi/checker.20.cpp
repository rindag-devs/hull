#include <algorithm>
#include <cstddef>
#include <string>

#include "cplib.hpp"

struct Input {
  std::string s;

  static auto read(cplib::var::Reader& in) -> Input {
    auto s = in.read(cplib::var::Line("s"));
    constexpr int N_DIGITS = 100000;
    if (s.size() != N_DIGITS + 2) {
      in.fail(cplib::format("Excepted {} digits after point, found {}", N_DIGITS, s.size() - 2));
    }
    return {s};
  }
};

struct Output {
  std::string s;

  static auto read(cplib::var::Reader& in, const Input&) -> Output {
    auto s = in.read(cplib::var::Line("s", cplib::Pattern("3\\.[0-9]+")));
    return {s};
  }

  static auto evaluate(cplib::evaluate::Evaluator&, const Output& pans, const Output& jans,
                       const Input&) -> cplib::evaluate::Result {
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
      n_correct_digit -= 2;
      std::size_t max_digit = jans.s.size() - 2;
      res &= cplib::evaluate::Result::pc(
          static_cast<double>(n_correct_digit) / static_cast<double>(max_digit),
          cplib::format("Correct digit {} / {}", n_correct_digit, max_digit));
    }
    return res;
  }
};

CPLIB_REGISTER_CHECKER(Input, Output)
