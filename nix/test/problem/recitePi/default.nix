{
  hull,
  config,
  cplib,
  ...
}:
{
  name = "recitePi";

  includes = [ cplib ];

  judger = hull.judger.answerOnly config;

  checker.src = ./checker.20.cpp;

  validator.src = ./validator.20.cpp;

  testCases = {
    hand-1 = {
      inputFile = ./data.in;
    };
  };

  tickLimit = 100 * 10000000;
  memoryLimit = 16 * 1024 * 1024;

  solutions =
    let
      ac = { score, ... }: score == 1;
      pc = { score, ... }: score > 0 && score < 1;
      unac = { score, ... }: score == 0;
    in
    {
      std = {
        src = ./solution/std.txt;
        mainCorrectSolution = true;
        subtaskPredictions = {
          "0" = ac;
        };
      };
      pc = {
        src = ./solution/pc.txt;
        subtaskPredictions = {
          "0" = pc;
        };
      };
      format-error = {
        src = ./solution/format-error.txt;
        subtaskPredictions = {
          "0" = unac;
        };
      };
    };

  targets = {
    default = hull.target.common;
    hydro = hull.target.hydro {
      type = "answerOnly";
    };
    uoj = hull.target.uoj {
      type = "answerOnly";
    };
  };
}
