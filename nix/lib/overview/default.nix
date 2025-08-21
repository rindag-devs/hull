{ hull, lib, ... }:

{
  mkOverview =
    problem:
    hull.document.mkTypstDocument problem {
      src = lib.fileset.toSource {
        root = ./.;
        fileset = ./main.typ;
      };
      typstPackages = [
        {
          name = "tablex";
          version = "0.0.9";
          hash = "sha256-yzg4LKpT1xfVUR5JyluDQy87zi2sU5GM27mThARx7ok=";
        }
        {
          name = "oxifmt";
          version = "1.0.0";
          hash = "sha256-edTDK5F2xFYWypGpR0dWxwM7IiBd8hKGQ0KArkbpHvI=";
        }
      ];
    };
}
