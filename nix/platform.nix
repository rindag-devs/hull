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
  self,
  nixpkgs,
  fenix,
  crane,
}:

let
  inherit (nixpkgs) lib;

  # A package set key needs a system double. An elaborated platform carries
  # that double in its `system` attribute.
  systemDouble = system: if builtins.isString system then system else system.system;

  mkContext =
    {
      buildSystem,
      targetSystem ? null,
    }:
    let
      buildPlatform = lib.systems.elaborate buildSystem;
      targetPlatform = if targetSystem == null then buildPlatform else lib.systems.elaborate targetSystem;
      native = lib.systems.equals buildPlatform targetPlatform;

      buildPkgs = nixpkgs.legacyPackages.${systemDouble buildSystem};

      # A native build uses the set of the build machine. A cross build uses the
      # cross set, which nixpkgs derives from the two systems.
      pkgs =
        if native then
          buildPkgs
        else
          import nixpkgs {
            localSystem = buildSystem;
            crossSystem = targetSystem;
          };

      # The WebAssembly sysroot is platform independent. Every target shares it.
      wasmSysroot = import ./pkgs/wasm32-wasi-wasip1.nix { pkgs = buildPkgs; };

      # The WebAssembly clang wrapper runs during a build. Its package set is the
      # set of the machine that starts the wrapper. LLVM comes from the argument,
      # so the cross wrapper still ships the LLVM build of the target machine.
      wasmClangFor =
        toolPkgs: llvm:
        toolPkgs.callPackage ./pkgs/clang.nix {
          llvmPackages = llvm;
          inherit (wasmSysroot) compiler-rt sysroot;
        };

      # The package set of the target platform, built for that platform. A
      # binary cache serves this set. A shipped program that a binary cache
      # serves comes from this set. A program that Hull builds itself comes from
      # the cross set.
      targetNativePkgs = if native then buildPkgs else import nixpkgs { localSystem = targetSystem; };

      rustPkgs = fenix.packages.${systemDouble buildSystem};
      rustTarget = pkgs.stdenv.hostPlatform.rust.cargoShortTarget;

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

      # rustc and cargo run on the build machine. A cross toolchain adds the
      # standard library of the target machine.
      toolchain =
        if native then
          rustToolchain
        else
          rustPkgs.combine [
            rustPkgs.stable.cargo
            rustPkgs.stable.rustc
            rustPkgs.targets.${rustTarget}.stable.rust-std
          ];

      craneLib = (crane.mkLib pkgs).overrideToolchain (_: toolchain);

      # The build toolset uses the package set and the toolchain of the build
      # machine, so its CLI runs during a build.
      buildCraneLib = (crane.mkLib buildPkgs).overrideToolchain (_: rustToolchain);

      # The source filter uses the crane library of the build machine, so a
      # native context and a cross context see the same source path.
      src = lib.cleanSourceWith {
        src = lib.cleanSource self;
        filter =
          path: type:
          buildCraneLib.filterCargoSources path type
          || lib.hasSuffix ".witx" (toString path)
          || lib.hasSuffix ".c" (toString path);
        name = "hull-cargo-source";
      };

      # The wrapper of the build machine. Every context shares this value, so a
      # native context and a cross context agree.
      buildWasmClang = wasmClangFor buildPkgs buildPkgs.llvmPackages;

      # A toolset runs on the host platform of its package set. The CLI of a
      # toolset runs its tests on the build machine, so the CLI uses the wasm
      # clang of the build machine.
      mkToolset =
        {
          toolsetPkgs,
          toolsetCraneLib,
          wasmClang,
          buildWasmClang,
          nixOutputMonitor,
        }:
        import ./pkgs {
          pkgs = toolsetPkgs;
          craneLib = toolsetCraneLib;
          inherit
            wasmSysroot
            src
            wasmClang
            buildWasmClang
            nixOutputMonitor
            ;
        };

      buildHullPkgs = mkToolset {
        toolsetPkgs = buildPkgs;
        toolsetCraneLib = buildCraneLib;
        wasmClang = buildWasmClang;
        nixOutputMonitor = buildPkgs.nix-output-monitor;
        inherit buildWasmClang;
      };

      hullPkgs = mkToolset {
        toolsetPkgs = pkgs;
        toolsetCraneLib = craneLib;
        wasmClang = wasmClangFor pkgs targetNativePkgs.llvmPackages;
        # The monitor renders the progress of `nix build`. Only a command of the
        # build machine starts `nix build`, so a target of another machine has
        # no monitor.
        nixOutputMonitor = if native then buildPkgs.nix-output-monitor else null;
        inherit buildWasmClang;
      };
    in
    {
      inherit buildSystem;
      targetSystem = if native then null else targetSystem;

      inherit
        pkgs
        buildPkgs
        targetNativePkgs
        hullPkgs
        buildHullPkgs
        rustToolchain
        ;

      forTarget =
        nextTargetSystem:
        mkContext {
          inherit buildSystem;
          targetSystem = nextTargetSystem;
        };

      matchesTarget =
        candidate:
        lib.systems.equals (lib.systems.elaborate (
          if candidate == null then buildSystem else candidate
        )) targetPlatform;
    };
in
{
  inherit mkContext;
}
