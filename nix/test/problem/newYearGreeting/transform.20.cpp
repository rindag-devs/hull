#include <cassert>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <string>
#include <utility>
#include <vector>

#include "cplib.hpp"
#include "problem.20.hpp"

CPLIB_REGISTER_GENERATOR(gen, args, salt = Var<cplib::var::String>("salt"));

auto generator_main() -> void {
  std::string s;
  std::cin >> s;
  assert(s == "encode");

  std::vector<std::pair<std::uint32_t, std::uint32_t>> vec(CNT);
  for (int i = 0; i < CNT; ++i) {
    std::cin >> vec[i].first >> vec[i].second;
  }
  gen.rnd.shuffle(vec);

  std::string encoded;
  std::ifstream first_out("firstOut");
  int type;
  first_out >> type;
  assert(type == 0);
  first_out >> encoded;
  first_out.close();

  int Q = gen.rnd.next(CNT - 50, CNT);
  std::cout << "decode\n";
  std::cout << encoded << '\n';
  std::cout << Q << '\n';
  for (int i = 0; i < Q; ++i) {
    std::cout << vec[i].first << '\n';
  }

  gen.quit_ok();
}
