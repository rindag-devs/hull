{
  hull,
  ...
}:
{
  name = "a-plus-b";

  includes = [ ./third_party/cplib/include ];

  checker.src = ./checker.20.cpp;

  validator.src = ./validator.20.cpp;

  generators = {
    rand.src = ./generator/rand.20.cpp;
  };

  traits = [
    "n_positive"
    "m_positive"
  ];

  testCases = {
    rand-1 = {
      generator = "rand";
      arguments = [
        "--n-min=1"
        "--n-max=10"
      ];
      traits = {
        n_positive = true;
        m_positive = true;
      };
      pretest = true;
      sample = true;
    };
    rand-2 = {
      generator = "rand";
      arguments = [
        "--n-min=1"
        "--n-max=10"
        "--same"
      ];
      traits = {
        n_positive = true;
        m_positive = true;
      };
    };
    rand-3 = {
      generator = "rand";
      arguments = [
        "--n-min=-10"
        "--n-max=-1"
      ];
      traits = {
        n_positive = false;
        m_positive = false;
      };
    };
    hand-1 = {
      inputFile = ./data/hand-1.in;
      traits = {
        n_positive = true;
        m_positive = true;
      };
    };
  };

  tickLimit = 100 * 10000000;
  memoryLimit = 16 * 1024 * 1024;

  subtasks = [
    {
      traits = {
        n_positive = true;
        m_positive = true;
      };
      fullScore = 0.5;
    }
    # fallback
    { fullScore = 0.5; }
  ];

  solutions =
    let
      ac = { score, ... }: score == 1;
      unac = { score, ... }: score == 0;
      tle_or_ac =
        { statuses, ... }: builtins.all (s: s == "accepted" || s == "time_limit_exceeded") statuses;
    in
    {
      std = {
        src = ./solution/std.20.cpp;
        mainCorrectSolution = true;
        subtaskPredictions = {
          "0" = ac;
          "1" = ac;
        };
      };
      wa-unsigned = {
        src = ./solution/wa-unsigned.20.cpp;
        subtaskPredictions = {
          "0" = ac;
          "1" = unac;
        };
      };
      tle = {
        src = ./solution/tle.20.cpp;
        subtaskPredictions = {
          "0" = tle_or_ac;
          "1" = tle_or_ac;
        };
      };
      mle-dynamic = {
        src = ./solution/mle-dynamic.20.cpp;
        subtaskPredictions = {
          "0" = unac;
          "1" = unac;
        };
      };
      mle-static = {
        src = ./solution/mle-static.20.cpp;
        subtaskPredictions = {
          "0" = unac;
          "1" = unac;
        };
      };
      re = {
        src = ./solution/re.20.cpp;
        subtaskPredictions = {
          "0" = unac;
          "1" = unac;
        };
      };
    };

  targets = {
    default = hull.target.default;
  };
}
