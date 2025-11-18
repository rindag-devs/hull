#pragma once

#include "cplib.hpp"

struct Input {
  static auto read(cplib::var::Reader& in) -> Input {}
};

struct Output {
  static auto read(cplib::var::Reader& in, const Input&) -> Output {}

  static auto evaluate(cplib::evaluate::Evaluator& ev, const Output& pans, const Output& jans,
                       const Input& in) -> cplib::evaluate::Result {}
};
