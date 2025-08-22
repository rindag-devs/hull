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

  name = "aPlusB";

  includes = [ (cplib + "/include") ];

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
    };
  };

  generators = {
    rand.src = ./generator/rand.20.cpp;
  };

  traits = {
    a_positive = { };
    b_positive = { };
  };

  testCases = {
    rand-1 = {
      generator = "rand";
      arguments = [
        "--n-min=1"
        "--n-max=10"
      ];
      traits = {
        a_positive = true;
        b_positive = true;
      };
      groups = [
        "sample"
        "pretest"
      ];
    };
    rand-2 = {
      generator = "rand";
      arguments = [
        "--n-min=1"
        "--n-max=10"
        "--same"
      ];
      traits = {
        a_positive = true;
        b_positive = true;
      };
    };
    rand-3 = {
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
    hand-1 = {
      inputFile = ./data/hand-1.in;
      traits = {
        a_positive = true;
        b_positive = true;
      };
      groups = [
        "sample"
        "pretest"
      ];
    };
  };

  tickLimit = 100 * 10000000;
  memoryLimit = 16 * 1024 * 1024;

  subtasks = [
    {
      traits = {
        a_positive = true;
        b_positive = true;
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

  documents =
    let
      languages = [
        "en"
        "zh"
      ];
      mkStatement = language: {
        "statement.${language}.pdf" = {
          path = hull.document.mkTypstDocument config {
            src = ./document/statement;
            inputs = { inherit language; };
            fontPaths = [
              "${pkgs.libertinus}/share/fonts/opentype"
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
                name = "oxifmt";
                version = "1.0.0";
                hash = "sha256-edTDK5F2xFYWypGpR0dWxwM7IiBd8hKGQ0KArkbpHvI=";
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
    default = hull.target.default;
  };
}
