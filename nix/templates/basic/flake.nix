{
  description = "A basic hull problem";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    cplib = {
      url = "github:rindag-devs/cplib/single-header-snapshot";
      flake = false;
    };
    hull = {
      url = "github:rindag-devs/hull";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.cplib.follows = "cplib";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      hull,
      cplib,
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSystem = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      perSystem = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          hullLib = hull.lib.${system};
          hullPackages = hull.packages.${system};
        in
        {
          devShells.default = pkgs.mkShell {
            packages = [
              hullPackages.default
            ];

            env = {
              CPLUS_INCLUDE_PATH = toString cplib;
            };
          };

          hullProblems.default = hullLib.evalProblem ./problem.nix { };

          treefmt = treefmt-nix.lib.evalModule pkgs {
            projectRootFile = "flake.nix";

            programs = {
              clang-format.enable = true;
              nixfmt.enable = true;
              typstyle.enable = true;
            };
          };
        }
      );

      devShells = forEachSystem (system: self.perSystem.${system}.devShells);
      formatter = forEachSystem (system: self.perSystem.${system}.treefmt.config.build.wrapper);
      hullProblems = forEachSystem (system: self.perSystem.${system}.hullProblems);
    };
}
