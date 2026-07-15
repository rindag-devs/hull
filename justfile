build:
  cargo build

clean:
  rm -rf ./result ./result-*
  cargo clean
  cargo clean --manifest-path nix/lib/problemTarget/uoj/supervisor/Cargo.toml

format:
  nix fmt
  cargo fmt
  cargo fmt --manifest-path nix/lib/problemTarget/uoj/supervisor/Cargo.toml
  biome format --write .
  git ls-files -z '*.c' '*.cc' '*.cpp' '*.cxx' '*.h' '*.hh' '*.hpp' '*.hxx' | xargs -0 -r sh -c 'for file do [ ! -e "$file" ] || printf "%s\0" "$file"; done' sh | xargs -0 -r clang-format -i --
  git ls-files '*.sh' | xargs -r shfmt -w -i 2
  git ls-files '*.typ' | xargs typstyle -i

update:
  nix flake update
  cargo update

lint:
  nix flake check --no-build
  cargo check
  cargo test
  cargo clippy --all-targets --all-features -- -D warnings
  biome check .
  cargo check --manifest-path nix/lib/problemTarget/uoj/supervisor/Cargo.toml
  cargo test --manifest-path nix/lib/problemTarget/uoj/supervisor/Cargo.toml
  cargo clippy --manifest-path nix/lib/problemTarget/uoj/supervisor/Cargo.toml --all-targets -- -D warnings

problem name *extra_args:
  cargo run -- build -p test.{{name}} {{extra_args}}

all-problems *extra_args:
  cargo run -- build-contest -c test.allProblems {{extra_args}}

integration *tests:
  scripts/integration_test.sh {{tests}}
