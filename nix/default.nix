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
  typix,
  cplib,
  cplibInitializers,
  x86_64-linux-gnu217-cross,
}:

let
  platform = import ./platform.nix {
    inherit
      self
      nixpkgs
      fenix
      crane
      ;
  };

  inherit (platform) mkContext;

  # The library of one context. `forTarget` returns this same library when the
  # asked target is the platform of the context.
  mkLib =
    context:
    let
      selfOfThisLib = import ./lib {
        inherit
          context
          cplib
          cplibInitializers
          x86_64-linux-gnu217-cross
          ;
        typixLib = typix.lib.${context.buildSystem};
        forTarget =
          targetSystem:
          if context.matchesTarget targetSystem then
            selfOfThisLib
          else
            mkLib (context.forTarget targetSystem);
      };
    in
    selfOfThisLib;

  forSystem =
    system:
    let
      context = mkContext { buildSystem = system; };
    in
    {
      inherit context;
      hull = mkLib context;
      hullPkgs = context.hullPkgs;
      pkgs = context.pkgs;
    };
in
{
  inherit mkContext mkLib forSystem;
}
