{
  hull,
  ...
}:
{
  name = "a-plus-b";

  checker = {
    src = ./checker.17.cpp;
  };

  generators = {
    rand = {
      src = ./generator/rand.17.cpp;
    };
  };

  traits = [ "negative" ];

  testCases = [
    {
      generator = "rand";
      arguments = [
        "--n-min=1"
        "--n-max=10"
      ];
      traits = [ "-negative" ];
      hash = "sha256-WqQrWWENIjH7SFvXtoLaC5oLEnr531Nj8f5C+wVBX0Y=";
      pretest = true;
      sample = true;
    }
    {
      generator = "rand";
      arguments = [
        "--n-min=1"
        "--n-max=10"
        "--salt=1234"
      ];
      traits = [ "-negative" ];
      hash = "sha256-WqQrWWENIjH7SFvXtoLaC5oLEnr531Nj8f5C+wVBX0Y=";
    }
    {
      generator = "rand";
      arguments = [
        "--n-min=-10"
        "--n-max=-1"
      ];
      traits = [ "+negative" ];
      hash = "sha256-WqQrWWENIjH7SFvXtoLaC5oLEnr531Nj8f5C+wVBX0Y=";
    }
  ];

  tickLimit = 1000 * 10000000;
  memoryLimit = 32 * 1024 * 1024;

  subtasks = [
    {
      traits = [ "-negative" ];
    }
    # fallback
    {
    }
  ];

  solutions = {
    std = {
      src = ./solution/std.17.cpp;
      mainCorrectSolution = true;
      subtaskPredictions = [
        "+0"
        "+1"
      ];
    };
  };

  targets = {
    default = hull.target.default;
  };
}
