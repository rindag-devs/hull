#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <tuple>
#include <variant>
#include <vector>

#include "cplib.hpp"

constexpr int CNT = 1024;

struct Pair {
  std::uint32_t k, v;

  static auto read(cplib::var::Reader& in) -> Pair {
    std::uint32_t k, v;
    std::tie(k, std::ignore, v) =
        in(cplib::var::u32("k"), cplib::var::space, cplib::var::u32("v", 0, CNT - 1));
    return {.k = k, .v = v};
  }
};

struct InputFirst {
  std::vector<Pair> pairs;

  static auto read(cplib::var::Reader& in) -> InputFirst {
    auto pairs = in.read(cplib::var::Vec(cplib::var::ExtVar<Pair>("pairs"), CNT, cplib::var::eoln));
    in.read(cplib::var::eoln);
    return {pairs};
  }
};

struct InputSecond {
  std::string encoded;
  std::int32_t Q;
  std::vector<std::uint32_t> indexes;

  static auto read(cplib::var::Reader& in) -> InputSecond {
    auto [encoded, Q] =
        in(cplib::var::Line("encoded", cplib::Pattern("[01]+")), cplib::var::i32("Q", 1, CNT));
    in.read(cplib::var::eoln);
    auto indexes = in.read(cplib::var::Vec(cplib::var::u32("indexes"), Q, cplib::var::eoln));
    in.read(cplib::var::eoln);
    return {.encoded = encoded, .Q = Q, .indexes = indexes};
  }
};

struct Input : std::variant<InputFirst, InputSecond> {
  static auto read(cplib::var::Reader& in) -> Input {
    auto type = in.read(cplib::var::Line("type", cplib::Pattern("encode|decode")));
    if (type == "encode") {
      auto first = in.read(cplib::var::ExtVar<InputFirst>("first"));
      return {first};
    } else {
      auto second = in.read(cplib::var::ExtVar<InputSecond>("second"));
      return {second};
    }
  }
};

struct OutputFirst {
  std::string encoded;
  static auto read(cplib::var::Reader& in) -> OutputFirst {
    auto encoded = in.read(cplib::var::String("encoded", cplib::Pattern("[01]+")));
    return {encoded};
  }
};

struct OutputSecond {
  std::vector<uint32_t> positions;

  static auto read(cplib::var::Reader& in, const InputSecond& inp) -> OutputSecond {
    auto positions = in.read(cplib::var::u32(0, CNT - 1) * inp.Q);
    return {positions};
  }
};

struct Output : std::variant<OutputFirst, OutputSecond> {
  static auto read(cplib::var::Reader& in, const Input& inp) -> Output {
    auto type = in.read(cplib::var::i32("type", 0, 1));
    if (type == 0) {
      auto res = in.read(cplib::var::ExtVar<OutputFirst>("first"));
      return {res};
    } else {
      auto res = in.read(cplib::var::ExtVar<OutputSecond>("second", std::get<1>(inp)));
      return {res};
    }
  }

  static auto evaluate(cplib::evaluate::Evaluator& ev, const Output& pans, const Output& jans,
                       const Input&) -> cplib::evaluate::Result {
    if (pans.index() != jans.index()) {
      ev.fail(cplib::format("Index mismatch: pans = {}, jans = {}", pans.index(), jans.index()));
    }

    if (pans.index() == 0) {
      auto encoded = std::get<0>(pans).encoded;
      constexpr std::array<std::size_t, 10> requirements = {100000, 43008, 40000, 30000, 20000,
                                                            15000,  14000, 13000, 12750, 12500};
      std::size_t n_satisfied = 0;
      for (auto len : requirements) {
        if (encoded.size() <= len) {
          ++n_satisfied;
        }
      }
      if (n_satisfied == 0) {
        return cplib::evaluate::Result::wa(
            cplib::format("Encoded string too big, length = {}", encoded.size()));
      }
      if (n_satisfied == requirements.size()) {
        return cplib::evaluate::Result::ac();
      }
      return cplib::evaluate::Result::pc(
          static_cast<double>(n_satisfied) / static_cast<double>(requirements.size()),
          cplib::format("length = {}, {} of {} requirements satisfied", encoded.size(), n_satisfied,
                        requirements.size()));
    } else {
      auto positions_p = std::get<1>(pans).positions;
      auto positions_j = std::get<1>(jans).positions;
      auto result = cplib::evaluate::Result::ac();
      result &= ev.eq("positions", positions_p, positions_j);
      return result;
    }
  }
};

auto traits(const Input& input) -> std::vector<cplib::validator::Trait> {
  return {
      {"k_lt_1024",
       [&]() {
         return input.index() == 0 && std::ranges::all_of(std::get<0>(input).pairs,
                                                          [](const Pair& p) { return p.k < 1024; });
       }},
  };
}
