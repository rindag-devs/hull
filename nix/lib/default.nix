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
  context,
  forTarget,
  typixLib,
  cplib,
  cplibInitializers,
  x86_64-linux-gnu217-cross,
}:

let
  inherit (context)
    pkgs
    buildPkgs
    targetNativePkgs
    hullPkgs
    buildHullPkgs
    buildSystem
    targetSystem
    ;

  lib = pkgs.lib;

  callSubLib =
    p:
    import p {
      inherit
        hull
        lib
        pkgs
        buildPkgs
        targetNativePkgs
        hullPkgs
        buildHullPkgs
        buildSystem
        forTarget
        typixLib
        cplib
        cplibInitializers
        x86_64-linux-gnu217-cross
        ;
    };

  # Every submodule reads the same library value, which carries its platform
  # context. `forTarget` returns another library of this shape.
  hull = {
    check = callSubLib ./check.nix;
    compile = callSubLib ./compile.nix;
    contestTarget = callSubLib ./contestTarget;
    docs = callSubLib ./docs.nix;
    document = callSubLib ./document.nix;
    evalContest = callSubLib ./evalContest.nix;
    evalProblem = callSubLib ./evalProblem.nix;
    judger = callSubLib ./judger;
    language = callSubLib ./language.nix;
    overview = callSubLib ./overview;
    patch = callSubLib ./patch.nix;
    problemTarget = callSubLib ./problemTarget;
    runWasm = callSubLib ./runWasm.nix;
    runtime = callSubLib ./runtime.nix;
    types = callSubLib ./types.nix;
    validate = callSubLib ./validate.nix;
    xcpcStatement = callSubLib ./xcpcStatement;

    contestModule = ./contestModule;
    problemModule = ./problemModule;
  }
  // {
    inherit
      pkgs
      buildPkgs
      targetNativePkgs
      hullPkgs
      buildHullPkgs
      buildSystem
      targetSystem
      forTarget
      ;
  };
in
hull
