{
  hull,
  lib,
  config,
  pkgs,
  cplib,
  ...
}:
{
  name = "exampleProblem";

  displayName.en = "example problem";

  tickLimit = 1000 * 10000000;
  memoryLimit = 512 * 1024 * 1024;

  includes = [
    cplib
    ./include
  ];

  generators.rand.src = ./generator/rand.20.cpp;

  validator = {
    src = ./validator.20.cpp;
    tests = {
      noEoln = {
        inputFile = builtins.toFile "noEoln.in" "1 2";
        prediction = { status, ... }: status == "invalid";
      };
      zero = {
        generator = "rand";
        arguments = [
          "--n-min=0"
          "--n-max=0"
          "--salt=0"
        ];
        prediction =
          { status, traits, ... }:
          status == "valid"
          &&
            traits == {
              a_positive = false;
              b_positive = false;
            };
      };
      tooBig = {
        inputFile = builtins.toFile "tooBig.in" "1001 1002\n";
        prediction = { status, ... }: status == "invalid";
      };
    };
  };

  checker = {
    src = ./checker.20.cpp;
    tests = {
      ac = {
        inputFile = builtins.toFile "ac.in" "1 2\n";
        outputFile = builtins.toFile "ac.out" "\t3\t \t\t\n";
        prediction = { status, ... }: status == "accepted";
      };
    };
  };

  traits = {
    a_positive = {
      descriptions.en = "$A > 0$.";
    };
    b_positive = {
      descriptions.en = "$B > 0$.";
    };
  };

  testCases =
    let
      maxTests = builtins.listToAttrs (
        map (i: {
          name = "max${toString i}";
          value = {
            generator = "rand";
            arguments = [
              "--n-min=-1000"
              "--n-max=1000"
              "--salt=${toString i}"
            ];
          };
        }) (lib.range 1 5)
      );
    in
    {
      manual1 = {
        inputFile = ./data/1.in;
        traits = {
          a_positive = true;
          b_positive = true;
        };
        groups = [
          "sample"
        ];
      };
    }
    // maxTests;

  subtasks = [
    {
      traits = {
        a_positive = true;
        b_positive = true;
      };
      fullScore = 0.5;
    }
    { fullScore = 0.5; }
  ];

  solutions =
    let
      ac = { score, ... }: score == 1.0;
      tleOrAc =
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
      bruteForce = {
        src = ./solution/bf.20.cpp;
        subtaskPredictions = {
          "0" = tleOrAc;
          "1" = tleOrAc;
        };
      };
    };

  documents =
    let
      languages = [ "en" ];
      mkStatement = language: {
        "statement.${language}.pdf" = {
          path = hull.document.mkProblemTypstDocument config {
            src = ./document/statement;
            inputs = { inherit language; };
            fontPaths = [
              "${pkgs.source-han-serif}/share/fonts/opentype/source-han-serif"
            ];
            typstPackages = [
              {
                name = "titleize";
                version = "0.1.1";
                hash = "sha256-Z0okd0uGhUDpdLXWpS+GvKVk1LSs15CE7l0l7kZqWLo=";
              }
              {
                name = "tablex";
                version = "0.0.9";
                hash = "sha256-yzg4LKpT1xfVUR5JyluDQy87zi2sU5GM27mThARx7ok=";
              }
            ];
          };
          inherit language;
          participantVisibility = true;
        };
      };
      statements = lib.mergeAttrsList (map mkStatement languages);
    in
    statements;

  targets = {
    default = hull.problemTarget.common;
  };
}
