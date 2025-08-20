#include <string>
#include <tuple>
#include <vector>

#include "cplib.hpp"

using cplib::var::Reader;

struct Input {
  std::string s;

  static auto read(Reader& in) -> Input {
    std::string s;
    std::tie(s, std::ignore) =
        in(cplib::var::String("s", cplib::Pattern("3\\.[0-9]+")), cplib::var::eoln);
    constexpr int N_DIGITS = 100000;
    if (s.size() != N_DIGITS + 2) {
      in.fail(cplib::format("Excepted {} digits after point, found {}", N_DIGITS, s.size() - 2));
    }
    return {s};
  }
};

CPLIB_REGISTER_VALIDATOR(Input,
                         [](const Input&) -> std::vector<cplib::validator::Trait> { return {}; });
