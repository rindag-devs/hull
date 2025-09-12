{
  hull,
  cplib,
  ...
}:
{
  name = "exampleProblem";

  includes = [ cplib ];

  checker = {
    src = ./checker.20.cpp;
  };

  validator = {
    src = ./validator.20.cpp;
  };

  generators = {
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
