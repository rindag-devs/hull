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
      cplib,
      cplibInitializers,
      x86_64-linux-gnu217-cross,
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSystem = nixpkgs.lib.genAttrs supportedSystems;
      mkPerSystem =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          rustPkgs = fenix.packages.${system};

          targetSystemToPkgsCrossName = {
            "x86_64-linux" = "gnu64";
            "aarch64-linux" = "aarch64-multiplatform";
            "x86_64-darwin" = "x86_64-darwin";
            "aarch64-darwin" = "aarch64-darwin";
          };

          rustToolchainFor =
            _p:
            rustPkgs.combine (
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

          rustToolchain = rustToolchainFor pkgs;
          craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchainFor;

          mkTargetHullPkgs =
            targetSystem:
            let
              targetCrossPkgsName =
                targetSystemToPkgsCrossName.${targetSystem}
                  or (throw "Unsupported cross target system `${targetSystem}`");
              targetCrossPkgs = pkgs.pkgsCross.${targetCrossPkgsName};
              targetNativePkgs = nixpkgs.legacyPackages.${targetSystem};
              targetPkgs =
                if targetSystem == system then
                  pkgs
                else
                  pkgs.pkgsCross.${targetSystemToPkgsCrossName.${targetSystem}};
              rustTarget = targetCrossPkgs.stdenv.hostPlatform.rust.rustcTarget;
              rustTargetEnv = pkgs.lib.toUpper (pkgs.lib.replaceStrings [ "-" "." ] [ "_" "_" ] rustTarget);
              baseWasmPkgs = (import ./nix/pkgs { inherit pkgs; }).wasm32-wasi-wasip1;
              targetRustToolchainFor =
                _p:
                rustPkgs.combine [
                  rustPkgs.stable.cargo
                  rustPkgs.stable.rustc
                  rustPkgs.targets.${rustTarget}.stable.rust-std
                ];
              targetCraneLib = (crane.mkLib targetCrossPkgs).overrideToolchain targetRustToolchainFor;
            in
            {
              nix-user-chroot = targetCrossPkgs.callPackage ./nix/pkgs/nix-user-chroot {
                pkgs = targetCrossPkgs;
              };

              wasm32-wasi-wasip1 = baseWasmPkgs // {
                clang = targetPkgs.callPackage ./nix/pkgs/clang.nix {
                  llvmPackages = targetNativePkgs.llvmPackages;
                  compiler-rt = baseWasmPkgs.compiler-rt;
                  sysroot = baseWasmPkgs.sysroot;
                };
              };

              default = targetCraneLib.buildPackage {
                src = targetCraneLib.cleanCargoSource self;
                cargoExtraArgs = "--target ${rustTarget}";
                doCheck = false;
                strictDeps = true;
                CARGO_BUILD_TARGET = rustTarget;
                "CARGO_TARGET_${rustTargetEnv}_LINKER" = "${targetCrossPkgs.stdenv.cc.targetPrefix}cc";
                "CC_${rustTargetEnv}" = "${targetCrossPkgs.stdenv.cc.targetPrefix}cc";
                meta = {
                  license = targetCrossPkgs.lib.licenses.lgpl3Plus;
                  mainProgram = "hull";
                };
              };
            };
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
              hullPkgs.wasm32-wasi-wasip1.clang
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
              hullPkgs
              targetHullPkgsForSystem
              targetPkgsForSystem
              targetHullForSystem
              typixLib
              cplib
              cplibInitializers
              x86_64-linux-gnu217-cross
              ;
          };

          hullPkgs = import ./nix/pkgs { inherit pkgs; } // {
            default = craneLib.buildPackage {
              src = craneLib.cleanCargoSource self;
              nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
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

          targetHullPkgsForSystem =
            targetSystem: if targetSystem == system then hullPkgs else mkTargetHullPkgs targetSystem;

          targetPkgsForSystem =
            targetSystem:
            if targetSystem == system then
              pkgs
            else
              pkgs.pkgsCross.${targetSystemToPkgsCrossName.${targetSystem}};

          targetHullForSystem =
            targetSystem:
            if targetSystem == system then
              hull
            else
              import ./nix/lib {
                pkgs = targetPkgsForSystem targetSystem;
                hullPkgs = targetHullPkgsForSystem targetSystem;
                inherit
                  targetHullPkgsForSystem
                  targetPkgsForSystem
                  targetHullForSystem
                  typixLib
                  cplib
                  cplibInitializers
                  x86_64-linux-gnu217-cross
                  ;
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
        };

      libForSystem = system: (mkPerSystem system).hull;
      targetHullPkgsForSystem =
        buildSystem: targetSystem: (mkPerSystem buildSystem).targetHullPkgsForSystem targetSystem;
      targetPkgsForSystem =
        buildSystem: targetSystem: (mkPerSystem buildSystem).targetPkgsForSystem targetSystem;
      targetHullForSystem =
        buildSystem: targetSystem: (mkPerSystem buildSystem).targetHullForSystem targetSystem;
    in
    {
      perSystem = forEachSystem mkPerSystem;

      devShells = forEachSystem (system: (mkPerSystem system).devShells);
      inherit
        libForSystem
        targetHullPkgsForSystem
        targetPkgsForSystem
        targetHullForSystem
        ;
      lib = forEachSystem libForSystem;
      packages = forEachSystem (system: (mkPerSystem system).hullPkgs);
      formatter = forEachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
      hullProblems = forEachSystem (system: (mkPerSystem system).hullProblems);
      hullContests = forEachSystem (system: (mkPerSystem system).hullContests);
      templates = import ./nix/templates;
      defaultTemplate = self.templates.basic;
    };
}
