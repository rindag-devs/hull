{
  description = "A minimal hull problem";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    cplib = {
      url = "github:/rindag-devs/cplib";
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

          hullProblems.default = hullLib.evalProblem ./problem.nix;
        }
      );

      devShells = forEachSystem (system: self.perSystem.${system}.devShells);
      hullProblems = forEachSystem (system: self.perSystem.${system}.hullProblems);
    };
}
