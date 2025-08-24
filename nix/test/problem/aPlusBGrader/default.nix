{
  hull,
  config,
  cplib,
  ...
}:
{
  name = "aPlusBGrader";

  tickLimit = 100 * 10000000;
  memoryLimit = 16 * 1024 * 1024;

  includes = [
    (cplib + "/include")
    ./include
  ];

  judger = hull.judger.batch config { extraObjects = [ ./grader.20.cpp ]; };

  checker.src = ./checker.20.cpp;

  validator.src = ./validator.20.cpp;

  generators.rand.src = ./generator/rand.20.cpp;

  traits = {
    a_positive = { };
    b_positive = { };
  };

  testCases = {
    rand-1 = {
      generator = "rand";
      arguments = [
        "--n-min=1"
        "--n-max=10"
      ];
      traits = {
        a_positive = true;
        b_positive = true;
      };
    };
    rand-2 = {
      generator = "rand";
      arguments = [
        "--n-min=-10"
        "--n-max=-1"
      ];
      traits = {
        a_positive = false;
        b_positive = false;
      };
    };
  };

  solutions =
    let
      ac = { score, ... }: score == 1;
      unac = { score, ... }: score == 0;
    in
    {
      std = {
        src = ./solution/std.98.cpp;
        mainCorrectSolution = true;
        subtaskPredictions = {
          "0" = ac;
        };
      };
      wa-unsigned = {
        src = ./solution/wa-unsigned.99.c;
        subtaskPredictions = {
          "0" = unac;
        };
      };
    };

  targets = {
    default = hull.target.default;
  };
}
