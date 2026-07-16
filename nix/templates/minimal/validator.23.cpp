#include "cplib.hpp"
#include "problem.23.hpp"

CPLIB_REGISTER_VALIDATOR(Input,
                         [](const Input &) -> std::vector<cplib::validator::Trait> { return {}; });
