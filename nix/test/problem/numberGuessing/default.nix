{
  hull,
  config,
  cplib,
  ...
}:
{
  name = "numberGuessing";

  includes = [ cplib ];

  judger = hull.judger.stdioInteraction config { realTimeLimitSeconds = 1; };

  checker.src = ./interactor.20.cpp;

  validator.src = ./validator.20.cpp;

  generators = {
    rand.src = ./generator/rand.20.cpp;
  };

  testCases = {
    rand-1 = {
      generator = "rand";
      arguments = [
        "--n-min=90"
        "--n-max=100"
      ];
    };
    rand-2 = {
      generator = "rand";
      arguments = [
        "--n-min=900000000"
        "--n-max=1000000000"
      ];
    };
  };

  tickLimit = 100 * 10000000;
  memoryLimit = 16 * 1024 * 1024;

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
      too-many-op = {
        src = ./solution/too-many-op.17.c;
        subtaskPredictions = {
          "0" = unac;
        };
      };
      infinity-read = {
        src = ./solution/infinity-read.20.cpp;
        subtaskPredictions = {
          "0" = unac;
        };
      };
    };

  targets = {
    default = hull.target.common;
    hydro = hull.target.hydro {
      type = "stdioInteraction";
    };
    uoj = hull.target.uoj {
      type = "stdioInteraction";
      twoStepInteraction = true;
    };
  };
}
