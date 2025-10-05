{
  lib,
  hull,
  config,
  cplib,
  ...
}:
{
  imports = [
    ./translation/en.nix
    ./translation/zh.nix
  ];

  name = "aPlusBGrader";

  tickLimit = 100 * 10000000;
  memoryLimit = 16 * 1024 * 1024;

  includes = [
    cplib
    ./include
  ];

  judger = hull.judger.batch config { extraObjects = [ ./grader.17.cpp ]; };

  checker.src = ./checker.20.cpp;

  validator.src = ./validator.20.cpp;

  generators.rand.src = ./generator/rand.20.cpp;

  traits = {
    a_positive = { };
    b_positive = { };
  };

  testCases = {
    rand1 = {
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
    rand2 = {
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
      waUnsigned = {
        src = ./solution/wa-unsigned.99.c;
        subtaskPredictions = {
          "0" = unac;
        };
      };
    };

  targets = {
    default = hull.problemTarget.common;
    hydro = hull.problemTarget.hydro {
      graderSrc = ./grader.17.cpp;
      testDataExtraFiles."add.h" = ./include/add.h;
      userExtraFiles = [ "add.h" ];
    };
    lemon = hull.problemTarget.lemon {
      graderSrc = ./grader.17.cpp;
      interactionLib = ./include/add.h;
      interactionLibName = "add.h";
      solutionExtNames = lib.mapAttrs (_: _: "cpp") config.solutions;
    };
    uoj = hull.problemTarget.uoj {
      graderSrcs.cpp = ./grader.17.cpp;
      extraRequireFiles."add.h" = ./include/add.h;
    };
    cms = hull.problemTarget.cms {
      graderSrcs.cpp = ./grader.17.cpp;
      extraSolFiles."add.h" = ./include/add.h;
    };
    luogu = hull.problemTarget.luogu {
      graderSrc = hull.patchCplibProgram {
        problemName = config.name;
        src = ./grader.17.cpp;
        extraEmbeds = [ ./include/add.h ];
        includeReplacements = [
          [
            "^add.h$"
            "/dev/null"
          ]
        ];
      };
    };
  };
}
