{
  hull,
  cplib,
  ...
}:
{
  name = "exampleProblem";

  includes = [
    cplib
    ./include
  ];

  generators = {
  };

  validator = {
    src = ./validator.23.cpp;
  };

  checker = {
    src = ./checker.23.cpp;
  };

  testCases = {
  };

  tickLimit = 1000 * 10000000;
  memoryLimit = 512 * 1024 * 1024;

  solutions =
    let
      ac = { score, ... }: score == 1.0;
    in
    {
      std = {
        src = ./solution/std.20.cpp;
        mainCorrectSolution = true;
        subtaskPredictions."0" = ac;
      };
    };

  targets = {
    default = hull.problemTarget.common;
  };
}
