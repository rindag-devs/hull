#include <tuple>
#include <vector>

#include "cplib.hpp"

using cplib::var::i32;
using cplib::var::Reader;

struct Input {
  int n, m;

  static auto read(Reader& in) -> Input {
    int n, m;
    std::tie(n, std::ignore) = in(i32("n", 1, 1e9), cplib::var::space);
    std::tie(m, std::ignore) = in(i32("m", 1, n), cplib::var::eoln);
    return {.n = n, .m = m};
  }
};

CPLIB_REGISTER_VALIDATOR(Input,
                         [](const Input&) -> std::vector<cplib::validator::Trait> { return {}; });
