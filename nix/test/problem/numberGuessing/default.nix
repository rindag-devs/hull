{
  lib,
  hull,
  config,
  cplib,
  ...
}:
{
  name = "numberGuessing";

  displayName = {
    en = "number guessing";
    zh = "猜数";
  };

  includes = [ cplib ];

  judger = hull.judger.stdioInteraction config { realTimeLimitSeconds = 10; };

  checker.src = ./interactor.20.cpp;

  validator.src = ./validator.20.cpp;

  generators = {
    rand.src = ./generator/rand.20.cpp;
  };

  testCases = {
    rand1 = {
      generator = "rand";
      arguments = [
        "--n-min=90"
        "--n-max=100"
      ];
    };
    rand2 = {
      generator = "rand";
      arguments = [
        "--n-min=900000000"
        "--n-max=1000000000"
      ];
    };
  };

  tickLimit = 100 * 10000000;
  memoryLimit = 128 * 1024 * 1024;

  solutions =
    let
      ac = { score, ... }: score == 1;
      unac = { score, ... }: score == 0;
      wa = { statuses, ... }: builtins.length statuses == 1 && builtins.elem "wrong_answer" statuses;
    in
    {
      std = {
        src = ./solution/std.98.cpp;
        mainCorrectSolution = true;
        subtaskPredictions = {
          "0" = ac;
        };
      };
      tooManyOp = {
        src = ./solution/too-many-op.17.c;
        subtaskPredictions = {
          "0" = wa;
        };
      };
      infinityRead = {
        src = ./solution/infinity-read.20.cpp;
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
    lemon = hull.problemTarget.lemon {
      solutionExtNames = {
        std = "cpp";
        tooManyOp = "c";
        infinityRead = "cpp";
      };
    };
    hydroLegacy = hull.problemTarget.legacy.hydro.stdioInteraction { };
    uojLegacy = hull.problemTarget.legacy.uoj.stdioInteraction { };
    qojLegacy = hull.problemTarget.legacy.uoj.stdioInteraction {
      twoStepInteraction = true;
    };
    cmsLegacy = hull.problemTarget.legacy.cms.stdioInteraction { };
    domjudgeLegacy = hull.problemTarget.legacy.domjudge.stdioInteraction { };
    luoguLegacy = hull.problemTarget.legacy.luogu.stdioInteraction { };
  };
}
