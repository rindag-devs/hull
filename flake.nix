/*
  This file is part of Hull.

  Hull is free software: you can redistribute it and/or modify it under the terms of the GNU
  Lesser General Public License as published by the Free Software Foundation, either version 3 of
  the License, or (at your option) any later version.

  Hull is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
  the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser
  General Public License for more details.

  You should have received a copy of the GNU Lesser General Public License along with Hull. If
  not, see <https://www.gnu.org/licenses/>.
*/

{
  description = "hull";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
    typix = {
      url = "github:loqusion/typix/0.3.2";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    tola = {
      url = "github:tola-rs/tola-ssg/v0.7.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    cplib = {
      url = "github:rindag-devs/cplib/single-header-snapshot";
      flake = false;
    };
    cplibInitializers = {
      url = "github:rindag-devs/cplib-initializers";
      flake = false;
    };
    x86_64-linux-gnu217-cross = {
      url = "github:aberter0x3f/x86_64-linux-gnu2.17-cross";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      fenix,
      crane,
      typix,
      tola,
      cplib,
      cplibInitializers,
      x86_64-linux-gnu217-cross,
    }:
    let
      hullNix = import ./nix {
        inherit
          self
          nixpkgs
          fenix
          crane
          typix
          cplib
          cplibInitializers
          x86_64-linux-gnu217-cross
          ;
      };

      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSystem = nixpkgs.lib.genAttrs supportedSystems;

      mkSystem =
        system:
        let
          context = hullNix.mkContext { buildSystem = system; };
          hull = hullNix.mkLib context;
          pkgs = nixpkgs.legacyPackages.${system};

          hullPkgs = context.hullPkgs // {
            docs = import ./docs/package.nix {
              inherit
                pkgs
                system
                tola
                ;
              optionsDocs = hull.docs.options;
            };
            optionsDocs = hull.docs.options;
          };
        in
        {
          inherit context hull hullPkgs;

          devShells.default = pkgs.mkShell {
            packages = [
              context.rustToolchain
              pkgs.cargo-deny
              pkgs.cargo-edit
              pkgs.cargo-watch
              pkgs.biome
              pkgs.clang-tools
              pkgs.git
              pkgs.just
              pkgs.libarchive
              pkgs.jq
              pkgs.pkg-config
              pkgs.nix-output-monitor
              pkgs._7zz
              pkgs.shfmt
              pkgs.typstyle
              pkgs.zstd
              context.hullPkgs.wasm32-wasi-wasip1.clang
            ];

            env = {
              RUST_SRC_PATH = "${context.rustToolchain}/lib/rustlib/src/rust/library";
              CPLUS_INCLUDE_PATH = toString cplib;
            };
          };

          hullProblems = {
            test = {
              aPlusB = hull.evalProblem ./nix/test/problem/aPlusB { };
              aPlusBGrader = hull.evalProblem ./nix/test/problem/aPlusBGrader { };
              numberGuessing = hull.evalProblem ./nix/test/problem/numberGuessing { };
              recitePi = hull.evalProblem ./nix/test/problem/recitePi { };
              newYearGreeting = hull.evalProblem ./nix/test/problem/newYearGreeting { };
              mst = hull.evalProblem ./nix/test/problem/mst { };
            };
          };

          hullContests = {
            test.aPlusBContest = hull.evalContest ./nix/test/contest/aPlusB.nix { };
            test.allProblems = hull.evalContest ./nix/test/contest/allProblems.nix { };
          };
        };
    in
    {
      devShells = forEachSystem (system: (mkSystem system).devShells);

      lib = forEachSystem (system: (mkSystem system).hull);

      packages = forEachSystem (
        system:
        nixpkgs.lib.filterAttrs (_: value: nixpkgs.lib.isDerivation value) (mkSystem system).hullPkgs
      );

      legacyPackages = forEachSystem (system: (mkSystem system).hullPkgs);

      formatter = forEachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);

      hullProblems = forEachSystem (system: (mkSystem system).hullProblems);

      hullContests = forEachSystem (system: (mkSystem system).hullContests);

      templates = (import ./nix/templates) // {
        default = self.templates.basic;
      };
    };
}
