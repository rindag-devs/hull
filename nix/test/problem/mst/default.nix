{
  hull,
  lib,
  config,
  pkgs,
  cplib,
  ...
}:
{
  imports = [
    ./translation/en.nix
    ./translation/zh.nix
  ];

  name = "mst";

  tickLimit = 1000 * 10000000;
  memoryLimit = 512 * 1024 * 1024;

  includes = [
    cplib
    ./include
  ];

  validator = {
    src = ./validator.23.cpp;
    participantVisibility = "src";
  };

  checker = {
    src = ./checker.23.cpp;
    participantVisibility = "src";
    tests =
      let
        inputFile = builtins.toFile "test.in" "1\n3 3\n1 2 1\n1 3 2\n2 3 3\n";
      in
      {
        ac = {
          inherit inputFile;
          outputFile = builtins.toFile "ac.out" "3\n1 2\n";
          prediction = { status, ... }: status == "accepted";
        };
        worse = {
          inherit inputFile;
          outputFile = builtins.toFile "worse.out" "4\n1 3\n";
          prediction = { status, ... }: status == "wrong_answer";
        };
        notMatch = {
          inherit inputFile;
          outputFile = builtins.toFile "notMatch.out" "1\n1 2\n";
          prediction = { status, ... }: status == "wrong_answer";
        };
      };
  };

  generators = {
    rand = {
      src = ./generator/rand.20.cpp;
      participantVisibility = "wasm";
    };
  };

  traits = {
    w_eq_1 = { };
  };

  testCases = {
    small = {
      generator = "rand";
      arguments = [
        "--T=3"
        "--n-min=5"
        "--n-max=5"
        "--m-min=10"
        "--m-max=10"
        "--w-min=0"
        "--w-max=5"
        "--salt=0"
      ];
      groups = [ "sample" ];
    };
    smallUnweighted = {
      generator = "rand";
      arguments = [
        "--T=3"
        "--n-min=5"
        "--n-max=5"
        "--m-min=10"
        "--m-max=10"
        "--w-min=1"
        "--w-max=1"
        "--salt=0"
      ];
      traits = {
        w_eq_1 = true;
      };
      groups = [ "sample" ];
    };
    max = {
      generator = "rand";
      arguments = [
        "--T=5"
        "--n-min=200000"
        "--n-max=200000"
        "--m-min=200000"
        "--m-max=200000"
        "--w-min=0"
        "--w-max=1000000000"
        "--salt=0"
      ];
    };
    maxUnweighted = {
      generator = "rand";
      arguments = [
        "--T=5"
        "--n-min=200000"
        "--n-max=200000"
        "--m-min=200000"
        "--m-max=200000"
        "--w-min=1"
        "--w-max=1"
        "--salt=0"
      ];
      traits = {
        w_eq_1 = true;
      };
    };
  };

  subtasks = [
    {
      traits = {
        w_eq_1 = true;
      };
      fullScore = 0.5;
    }
    # fallback
    { fullScore = 0.5; }
  ];

  solutions = {
    std = {
      src = ./solution/std.14.cpp;
      mainCorrectSolution = true;
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
              {
                name = "diagraph";
                version = "0.3.6";
                hash = "sha256-U/KxwlNyCIFHyMJKkjeQ4NDCYZhqNgM+oxJZ8Lov3nA=";
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
