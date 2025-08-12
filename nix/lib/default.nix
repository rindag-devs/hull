{ pkgs, hullPkgs }:

let
  problemModule = ./problemModule.nix;

  hull = {
    compile = import ./compile.nix { inherit pkgs hullPkgs hull; };
    judger = import ./judger.nix { inherit pkgs; };
    target = import ./target.nix { inherit pkgs hull; };
    types = import ./types.nix {
      inherit hull;
      inherit (pkgs) lib;
    };
    language = import ./language.nix { inherit pkgs hullPkgs; };
    generate = import ./generate.nix { inherit pkgs hullPkgs; };

    inherit problemModule;

    # A helper function to evaluate a user's problem definition.
    # It takes a user-provided attribute set (the problem definition)
    # and evaluates it against our module system.
    evalProblem =
      problemAttrs:
      pkgs.lib.evalModules {
        # The list of modules to evaluate.
        # We have our main problem module and the user's configuration.
        modules = [
          problemModule
          problemAttrs
        ];

        specialArgs = {
          inherit hull;
        };
      };
  };
in
hull
