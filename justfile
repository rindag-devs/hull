build:
  cargo build

clean:
  rm -rf ./result ./result-*
  cargo clean

format:
  nix fmt
  cargo fmt
  biome format --write .
  git ls-files '*.c' '*.cc' '*.cpp' '*.cxx' '*.h' '*.hh' '*.hpp' '*.hxx' | xargs clang-format -i
  git ls-files '*.sh' | xargs -r shfmt -w -i 2
  git ls-files '*.typ' | xargs typstyle -i

update:
  nix flake update
  cargo update

lint:
  cargo check
  cargo test
  cargo clippy --all-targets --all-features -- -D warnings
  biome check .

problem name *extra_args:
  cargo run -- build -p test.{{name}} {{extra_args}}

all-problems *extra_args:
  cargo run -- build-contest -c test.allProblems {{extra_args}}

integration *tests:
  nix develop --command scripts/integration_test.sh {{tests}}
