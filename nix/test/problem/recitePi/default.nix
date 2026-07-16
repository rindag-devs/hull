{
  lib,
  hull,
  config,
  cplib,
  ...
}:
{
  name = "recitePi";

  displayName = {
    en = "recite pi";
    zh = "背诵圆周率";
  };

  includes = [
    cplib
    ./include
  ];

  judger = hull.judger.answerOnly config;

  checker.src = ./checker.23.cpp;

  validator.src = ./validator.23.cpp;

  testCases = {
    hand1 = {
      inputFile = ./data.in;
    };
  };

  tickLimit = 100 * 10000000;
  memoryLimit = 128 * 1024 * 1024;

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
      formatError = {
        src = ./solution/format-error.txt;
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
        std = "txt";
        pc = "txt";
        formatError = "txt";
      };
    };
    hydroLegacy = hull.problemTarget.legacy.hydro.answerOnly { };
    uojLegacy = hull.problemTarget.legacy.uoj.answerOnly { };
    cmsLegacy = hull.problemTarget.legacy.cms.answerOnly { };
    luoguLegacy = hull.problemTarget.legacy.luogu.answerOnly { };
  };
}
