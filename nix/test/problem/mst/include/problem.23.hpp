#include <algorithm>
#include <cstdint>
#include <optional>
#include <ranges>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

#include "cplib.hpp"

struct UF {
  std::vector<std::int32_t> fa, sz;

  inline explicit UF(std::int32_t n)
      : fa(std::views::iota(0, n) | std::ranges::to<std::vector>()), sz(n, 1) {}

  inline auto F(std::int32_t x) -> std::int32_t {
    if (x != fa[x]) x = (fa[x] = fa[fa[x]]);
    return x;
  }

  inline auto U(std::int32_t x, std::int32_t y) -> void {
    x = F(x), y = F(y);
    if (x == y) return;
    if (sz[x] < sz[y]) std::swap(x, y);
    sz[x] += sz[y], fa[y] = x;
  }
};

struct Edge {
  std::int32_t u, v, w;

  static auto read(cplib::var::Reader &in, int n) -> Edge {
    std::int32_t u, v, w;
    std::tie(u, std::ignore, v, std::ignore, w) =
        in(cplib::var::i32("u", 1, n), cplib::var::space, cplib::var::i32("v", 1, n),
           cplib::var::space, cplib::var::i32("w", 0, 1e9));

    return {.u = u, .v = v, .w = w};
  }
};

struct TestCaseInput {
  std::int32_t idx, n, m;
  std::vector<Edge> edges;

  static auto read(cplib::var::Reader &in, std::int32_t tc_idx) -> TestCaseInput {
    std::int32_t n, m;
    std::tie(n, std::ignore, m, std::ignore) = in(cplib::var::i32("n", 1, 2e5), cplib::var::space,
                                                  cplib::var::i32("m", 1, 2e5), cplib::var::eoln);
    auto edges =
        in.read(cplib::var::Vec(cplib::var::ExtVar<Edge>("edges", n), m, cplib::var::eoln));
    in.read(cplib::var::eoln);

    if (in.get_trace_level() >= cplib::trace::Level::FULL) {
      using jV = cplib::json::Value;
      using jM = cplib::json::Map;
      in.attach_tag(
          "hull/graph",
          jV(jM{{"name", jV(cplib::format("graph_{}", tc_idx))},
                {"nodes", jV(std::views::iota(1, n + 1) | std::views::transform([](std::int32_t x) {
                               return jV(std::to_string(x));
                             }) |
                             std::ranges::to<std::vector>())},
                {"edges", jV(edges | std::views::transform([](const auto &e) {
                               return jV(jM{
                                   {"u", jV(std::to_string(e.u))},
                                   {"v", jV(std::to_string(e.v))},
                                   {"w", jV(std::to_string(e.w))},
                                   {"ordered", jV(false)},
                               });
                             }) |
                             std::ranges::to<std::vector>())}}));
      in.attach_tag("hull/case", jV(tc_idx));
    }

    return {.idx = tc_idx, .n = n, .m = m, .edges = std::move(edges)};
  }
};

struct Input {
  std::vector<TestCaseInput> test_cases;

  static auto read(cplib::var::Reader &in) -> Input {
    std::int32_t T;
    std::tie(T, std::ignore) = in(cplib::var::i32("T", 1, 5), cplib::var::eoln);
    auto test_cases = in.read(cplib::var::ExtVec<TestCaseInput>(
        "test_cases", std::views::iota(0, T), cplib::var::Separator(std::nullopt)));
    return {.test_cases = std::move(test_cases)};
  }
};

struct TestCaseOutput {
  std::int32_t idx;
  std::int64_t ans;
  std::vector<std::int32_t> plan;

  static auto read(cplib::var::Reader &in, const TestCaseInput &inp) -> TestCaseOutput {
    auto [ans, plan] = in(cplib::var::i64("ans", 0, std::nullopt),
                          cplib::var::i32("plan", 1, inp.m) * (inp.n - 1));
    std::ranges::sort(plan);
    if (std::ranges::unique(plan).end() != plan.end()) {
      in.fail("Duplicate edges in plan");
    }
    UF uf(inp.n);
    std::int64_t sum = 0;
    for (const auto &idx : plan) {
      const auto &[u, v, w] = inp.edges[idx - 1];
      uf.U(u - 1, v - 1);
      sum += w;
    }
    for (std::int32_t i : std::views::iota(1, inp.n)) {
      if (uf.F(0) != uf.F(i)) {
        in.fail(cplib::format("Node 1 and {} are not connected", i + 1));
      }
    }
    if (sum != ans) {
      in.fail("sum and ans not match");
    }
    return {.idx = inp.idx, .ans = ans, .plan = std::move(plan)};
  }

  static auto evaluate(cplib::evaluate::Evaluator &ev, const TestCaseOutput &pans,
                       const TestCaseOutput &jans) -> cplib::evaluate::Result {
    auto res = cplib::evaluate::Result::ac();
    if (pans.ans < jans.ans) {
      ev.fail(
          cplib::format("Participant's answer ({}) is less than jury's answer ({})! This indicates "
                        "a judge error.",
                        pans.ans, jans.ans));
    }
    res &= ev.eq("sum", pans.ans, jans.ans);
    return res;
  }
};

struct Output {
  std::vector<TestCaseOutput> test_cases;

  static auto read(cplib::var::Reader &in, const Input &inp) -> Output {
    auto test_cases = in.read(cplib::var::ExtVec<TestCaseOutput>(
        "test_cases", inp.test_cases, cplib::var::Separator(std::nullopt)));
    return {.test_cases = std::move(test_cases)};
  }

  static auto evaluate(cplib::evaluate::Evaluator &ev, const Output &pans, const Output &jans,
                       const Input &) -> cplib::evaluate::Result {
    auto res = cplib::evaluate::Result::ac();

    for (const auto &[p_case, j_case] : std::views::zip(pans.test_cases, jans.test_cases)) {
      res &= ev(cplib::format("test_case_{}", p_case.idx), p_case, j_case);
    }
    return res;
  }
};

inline auto traits(const Input &input) -> std::vector<cplib::validator::Trait> {
  return {{"w_eq_1", [&input]() {
             return std::ranges::all_of(input.test_cases, [](const auto &test_case) {
               return std::ranges::all_of(test_case.edges, [](const auto &e) { return e.w == 1; });
             });
           }}};
}
