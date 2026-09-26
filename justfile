build:
  cargo build

clean:
  rm -rf ./result ./result-*
  cargo clean
  cargo clean --manifest-path nix/lib/problemTarget/uoj/supervisor/Cargo.toml

format:
  nix fmt

update:
  nix flake update
  cargo update

lint:
  nix flake check --no-build
  cargo check
  cargo test
  RUSTDOCFLAGS="-D missing_docs" cargo doc --no-deps
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
