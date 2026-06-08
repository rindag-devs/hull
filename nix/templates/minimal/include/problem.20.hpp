#pragma once

#include "cplib.hpp"

struct Input {
  static auto read(cplib::var::Reader &in) -> Input { cplib::panic("TODO: implement Input::read"); }
};

struct Output {
  static auto read(cplib::var::Reader &in, const Input &) -> Output {
    cplib::panic("TODO: implement Output::read");
  }

  static auto evaluate(cplib::evaluate::Evaluator &ev, const Output &pans, const Output &jans,
                       const Input &in) -> cplib::evaluate::Result {
    cplib::panic("TODO: implement Output::evaluate");
  }
};
