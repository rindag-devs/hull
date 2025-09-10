{
  pkgs,
  hull,
  lib,
  cplib,
  cplibInitializers,
  ...
}:

{
  common = import ./common.nix {
    inherit
      lib
      hull
      pkgs
      ;
  };

  hydro = import ./hydro.nix {
    inherit
      lib
      hull
      pkgs
      cplib
      cplibInitializers
      ;
  };

  lemon = import ./lemon.nix {
    inherit
      lib
      hull
      pkgs
      cplib
      cplibInitializers
      ;
  };
}
