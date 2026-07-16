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
  memoryLimit = 128 * 1024 * 1024;

  includes = [
    cplib
    ./include
  ];

  judger = hull.judger.batch config { extraObjects = [ ./grader.17.cpp ]; };

  checker.src = ./checker.23.cpp;

  validator.src = ./validator.23.cpp;

  generators.rand.src = ./generator/rand.23.cpp;

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
      traitHints = {
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
      traitHints = {
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

  documents =
    let
      languages = [
        "en"
        "zh"
      ];
      mkStatement = language: {
        "statement.${language}.pdf" = {
          path = hull.xcpcStatement config {
            statement = "${./document/statement}/${language}.typ";
            displayLanguage = language;
          };
          displayLanguage = language;
          participantVisibility = true;
        };
      };
      statements = lib.mergeAttrsList (map mkStatement languages);
    in
    statements;

  targets = {
    default = hull.problemTarget.common;
    hydroLegacy = hull.problemTarget.legacy.hydro.batch {
      graderSrc = ./grader.17.cpp;
      testDataExtraFiles."add.h" = ./include/add.h;
      userExtraFiles = [ "add.h" ];
    };
    lemonLegacy = hull.problemTarget.legacy.lemon.batch {
      graderSrc = ./grader.17.cpp;
      interactionLib = ./include/add.h;
      interactionLibName = "add.h";
      solutionExtNames = lib.mapAttrs (_: _: "cpp") config.solutions;
    };
    lemon = hull.problemTarget.lemon {
      solutionExtNames = lib.mapAttrs (_: _: "cpp") config.solutions;
    };
    uojLegacy = hull.problemTarget.legacy.uoj.batch {
      graderSrcs.cpp = ./grader.17.cpp;
      extraRequireFiles."add.h" = ./include/add.h;
    };
    cmsLegacy = hull.problemTarget.legacy.cms.batch {
      graderSrcs.cpp = ./grader.17.cpp;
      extraSolFiles."add.h" = ./include/add.h;
    };
    luoguLegacy = hull.problemTarget.legacy.luogu.batch {
      graderSrc = hull.patch {
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
