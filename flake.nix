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
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
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
      url = "github:/rindag-devs/cplib/single-header-snapshot";
      flake = false;
    };
    cplibInitializers = {
      url = "github:/rindag-devs/cplib-initializers";
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
      cplibInitializers,
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
              CPLUS_INCLUDE_PATH = toString cplib;
            };
          };

          typixLib = typix.lib.${system};

          hull = import ./nix/lib {
            inherit
              pkgs
              typixLib
              cplib
              cplibInitializers
              ;
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
              meta = {
                license = pkgs.lib.licenses.lgpl3Plus;
                mainProgram = "hull";
              };
            };
            docs = hull.docs;
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
            test.allProblems = hull.evalContest ./nix/test/contest/allProblems.nix { };
          };
        }
      );

      devShells = forEachSystem (system: self.perSystem.${system}.devShells);
      lib = forEachSystem (system: self.perSystem.${system}.hull);
      packages = forEachSystem (system: self.perSystem.${system}.packages);
      formatter = forEachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
      hullProblems = forEachSystem (system: self.perSystem.${system}.hullProblems);
      hullContests = forEachSystem (system: self.perSystem.${system}.hullContests);
      templates = import ./nix/templates;
      defaultTemplate = self.templates.basic;
    };
}
