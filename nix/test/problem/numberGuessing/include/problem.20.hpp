#pragma once

#include <cstdint>
#include <format>
#include <tuple>
#include <variant>
#include <vector>

#include "cplib.hpp"

struct Input {
  std::int32_t n, m;

  static auto read(cplib::var::Reader &in) -> Input {
    std::int32_t n, m;
    std::tie(n, std::ignore) =
        in(cplib::var::i32("n", 1, 1'000'000'000), cplib::var::space);
    std::tie(m, std::ignore) = in(cplib::var::i32("m", 1, n), cplib::var::eoln);
    return {.n = n, .m = m};
  }
};

struct Query {
  std::int32_t x;

  static auto read(cplib::var::Reader &in, const Input &input) -> Query {
    auto x = in.read(cplib::var::i32("x", 1, input.n));
    return {x};
  }
};

struct Answer {
  std::int32_t x;

  static auto read(cplib::var::Reader &in, const Input &input) -> Answer {
    auto x = in.read(cplib::var::i32("x", 1, input.n));
    return {x};
  }
};

struct Operate : std::variant<Query, Answer> {
  static auto read(cplib::var::Reader &in, const Input &input) -> Operate {
    auto op = in.read(cplib::var::String("type", cplib::Pattern("[QA]")));
    if (op == "Q") {
      return {in.read(cplib::var::ExtVar<Query>("Q", input))};
    }
    return {in.read(cplib::var::ExtVar<Answer>("A", input))};
  }
};

inline auto traits(const Input &) -> std::vector<cplib::validator::Trait> { return {}; }

inline auto run_interactor(auto &intr) -> void {
  auto input = intr.inf.read(cplib::var::ExtVar<Input>("input"));

  intr.to_user << input.n << '\n';

  int use_cnt = 0;
  while (true) {
    auto op = intr.from_user.read(cplib::var::ExtVar<Operate>("operate", input));
    if (op.index() == 0) {
      const auto &query = std::get<0>(op);
      if (use_cnt >= 50) intr.quit_wa("Too many queries");
      if (query.x > input.m) {
        intr.to_user << ">\n";
      } else if (query.x == input.m) {
        intr.to_user << "=\n";
      } else {
        intr.to_user << "<\n";
      }
      ++use_cnt;
    } else {
      const auto &answer = std::get<1>(op);
      if (answer.x == input.m) {
        intr.quit_ac();
      } else {
        intr.quit_wa(std::format("Expected {}, got {}", input.m, answer.x));
      }
    }
  }
}
