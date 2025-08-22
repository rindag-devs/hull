let
  welcomeText = ''
    # Getting Started

    - Run `nix develop` to enter the development environment
    - Run `hull build` to build your problem
    - Run `hull judge path/to/solution/source/file` to judge a solution
  '';
in
{
  minimal = {
    path = ./minimal;
    description = "A minimal hull problem";
  };
  basic = {
    path = ./basic;
    description = "A basic batch problem with English statement";
    inherit welcomeText;
  };
}
