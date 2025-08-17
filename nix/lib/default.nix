{
  pkgs,
  hullPkgs,
  typixLib,
}:

let
  problemModule = ./problemModule;

  hull = {
    compile = import ./compile.nix { inherit hull pkgs hullPkgs; };
    docs = import ./docs.nix { inherit hull pkgs; };
    document = import ./document.nix { inherit pkgs typixLib; };
    generate = import ./generate.nix { inherit hull pkgs hullPkgs; };
    judge = import ./judge.nix { inherit pkgs hullPkgs; };
    judger = import ./judger.nix { inherit pkgs; };
    language = import ./language.nix { inherit pkgs hullPkgs; };
    target = import ./target.nix { inherit hull pkgs; };
    types = import ./types.nix {
      inherit hull;
      inherit (pkgs) lib;
    };
    validate = import ./validate.nix { inherit pkgs hullPkgs; };

    inherit problemModule;

    # A helper function to evaluate a user's problem definition.
    # It takes a user-provided attribute set (the problem definition)
    # and evaluates it against our module system.
    evalProblem =
      problemAttrs:
      let
        problem = pkgs.lib.evalModules {
          # The list of modules to evaluate.
          # We have our main problem module and the user's configuration.
          modules = [
            problemModule
            problemAttrs
          ];

          specialArgs = { inherit pkgs hull; };
        };

        problemAssertWarn =
          pkgs.lib.asserts.checkAssertWarn problem.config.assertions problem.config.warnings
            problem;
      in
      problemAssertWarn;
  };
in
hull
