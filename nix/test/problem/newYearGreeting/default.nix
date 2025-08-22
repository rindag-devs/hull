{
  hull,
  lib,
  cplib,
  ...
}:
{
  imports = [ ./judger.nix ];

  name = "newYearGreeting";

  tickLimit = 1000 * 10000000;
  memoryLimit = 256 * 1024 * 1024;

  includes = [
    (cplib + "/include")
    ./include
  ];

  checker.src = ./checker.20.cpp;

  validator.src = ./validator.20.cpp;

  generators = {
    rand.src = ./generator/rand.20.cpp;
  };

  traits = {
    k_lt_1024 = { };
  };

  testCases =
    let
      small = map (i: {
        name = "small-${toString i}";
        value = {
          generator = "rand";
          arguments = [
            "--k-max=1023"
            "--salt=${toString i}"
          ];
          traits = {
            k_lt_1024 = true;
          };
        };
      }) (lib.range 1 5);
      big = map (i: {
        name = "big-${toString i}";
        value = {
          generator = "rand";
          arguments = [
            "--k-max=4294967295"
            "--salt=${toString i}"
          ];
        };
      }) (lib.range 1 10);
    in
    builtins.listToAttrs (small ++ big);

  subtasks = [
    {
      traits = {
        k_lt_1024 = true;
      };
      fullScore = 0.3;
    }
    { fullScore = 0.7; }
  ];

  solutions =
    let
      ac = { score, ... }: score == 1;
      unac = { score, ... }: score == 0;
      pc20 = { score, ... }: score == 0.2;
    in
    {
      std = {
        src = ./solution/std.98.cpp;
        mainCorrectSolution = true;
        subtaskPredictions = {
          "0" = ac;
          "1" = ac;
        };
      };
      small-only = {
        src = ./solution/small-only.98.cpp;
        subtaskPredictions = {
          "0" = ac;
          "1" = unac;
        };
      };
      brute-force = {
        src = ./solution/brute-force.98.cpp;
        subtaskPredictions = {
          "0" = pc20;
          "1" = pc20;
        };
      };
    };

  targets = {
    default = hull.target.default;
  };
}
