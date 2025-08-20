#include "cplib.hpp"

using cplib::var::Reader, cplib::var::i32, cplib::evaluate::Result, cplib::evaluate::Evaluator;

struct Input {
  int a, b;

  static auto read(Reader& in) -> Input {
    auto a = in.read(i32("a", -1000, 1000));
    auto b = in.read(i32("b", -1000, 1000));
    return {.a = a, .b = b};
  }
};

struct Output {
  int ans;

  static auto read(Reader& in, const Input&) -> Output {
    auto ans = in.read(i32("ans", -2000, 2000));
    return {ans};
  }

  static auto evaluate(Evaluator& ev, const Output& pans, const Output& jans, const Input&)
      -> Result {
    auto res = Result::ac();
    res &= ev.eq("ans", pans.ans, jans.ans);
    return res;
  }
};

CPLIB_REGISTER_CHECKER(Input, Output);
