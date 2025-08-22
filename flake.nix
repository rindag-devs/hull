{
  description = "hull";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
    typix = {
      url = "github:loqusion/typix/0.3.2";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    cplib = {
      url = "github:/rindag-devs/cplib";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      fenix,
      crane,
      typix,
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
          rustPkgs = fenix.packages.${system};

          rustToolchain = rustPkgs.combine (
            with rustPkgs.stable;
            [
              rust-analyzer
              clippy
              rustc
              cargo
              rustfmt
              rust-src
            ]
          );

          craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;
        in
        rec {
          devShells.default = pkgs.mkShell {
            packages = [
              rustToolchain
              pkgs.cargo-deny
              pkgs.cargo-edit
              pkgs.cargo-watch
              pkgs.pkg-config
              pkgs.nix-output-monitor
              packages.wasm-judge-clang
            ];

            env = {
              RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";
              CPLUS_INCLUDE_PATH = "${cplib}/include";
            };
          };

          typixLib = typix.lib.${system};

          hull = import ./nix/lib {
            inherit pkgs typixLib cplib;
            hullPkgs = packages;
          };

          packages = import ./nix/pkgs { inherit pkgs; } // {
            default = craneLib.buildPackage {
              src = craneLib.cleanCargoSource ./.;
              nativeBuildInputs = [
                pkgs.makeBinaryWrapper
              ];
              postInstall = ''
                wrapProgram $out/bin/hull \
                  --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.nix-output-monitor ]}
              '';
            };
            docs = hull.docs;
          };

          hullProblems = {
            test = {
              aPlusB = hull.evalProblem ./nix/test/problem/aPlusB;
              aPlusBGrader = hull.evalProblem ./nix/test/problem/aPlusBGrader;
              numberGuessing = hull.evalProblem ./nix/test/problem/numberGuessing;
              recitePi = hull.evalProblem ./nix/test/problem/recitePi;
              newYearGreeting = hull.evalProblem ./nix/test/problem/newYearGreeting;
            };
          };
        }
      );

      devShells = forEachSystem (system: self.perSystem.${system}.devShells);
      lib = forEachSystem (system: self.perSystem.${system}.hull);
      packages = forEachSystem (system: self.perSystem.${system}.packages);
      formatter = forEachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
      hullProblems = forEachSystem (system: self.perSystem.${system}.hullProblems);
      templates = import ./nix/templates;
      defaultTemplate = self.templates.basic;
    };
}
