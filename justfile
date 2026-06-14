default:
	@echo "No command specified" >&2
	@exit 1

clean:
	rm -rf ./result ./result-*
	cargo clean

format:
	nix fmt
	cargo fmt
	biome format --write .
	git ls-files '*.c' '*.cc' '*.cpp' '*.cxx' '*.h' '*.hh' '*.hpp' '*.hxx' | xargs clang-format -i
	git ls-files '*.typ' | xargs typstyle -i

update:
	nix flake update
	cargo update

problem name *extra_args:
	cargo run -- build -p test.{{name}} {{extra_args}}

all-problems *extra_args:
	cargo run -- build-contest -c test.allProblems {{extra_args}}
