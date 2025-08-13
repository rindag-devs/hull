{
  hull,
  ...
}:
{
  name = "a-plus-b";

  includes = [ ./third_party/cplib/include ];

  checker = {
    src = ./checker.20.cpp;
  };

  validator = {
    src = ./validator.20.cpp;
  };

  generators = {
    rand = {
      src = ./generator/rand.20.cpp;
    };
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
      inputHash = "sha256-/j0gXXAo0lQOif4l2t9YNKwp2c2eAx2lHburupE5+pA=";
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
      inputHash = "sha256-9lzqriRt4CE1wTJv9RiL3RZsl0nAIckeScC5p5+ccmI=";
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
      inputHash = "sha256-aiHMd589gYJJF04XMA9AdVeBYWVWM1MVs4Zsab+YVi8=";
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
    }
    # fallback
    {
    }
  ];

  solutions = {
    std = {
      src = ./solution/std.20.cpp;
      mainCorrectSolution = true;
      subtaskPredictions = {
        "0" = true;
        "1" = true;
      };
    };
  };

  targets = {
    default = hull.target.default;
  };
}
