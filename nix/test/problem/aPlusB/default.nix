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

  tickLimit = 100 * 10000000;
  memoryLimit = 16 * 1024 * 1024;

  includes = [ cplib ];

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
    participantVisibility = "src";
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

  generators = {
    rand = {
      src = ./generator/rand.20.cpp;
      participantVisibility = "wasm";
    };
  };

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
        "--salt=0"
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
    rand2 = {
      generator = "rand";
      arguments = [
        "--n-min=1"
        "--n-max=10"
        "--same"
        "--salt=0"
      ];
      groups = [
        "sample_large"
        "pretest"
      ];
      traits = {
        a_positive = true;
        b_positive = true;
      };
    };
    rand3 = {
      generator = "rand";
      arguments = [
        "--n-min=-10"
        "--n-max=-1"
        "--salt=0"
      ];
      traits = {
        a_positive = false;
        b_positive = false;
      };
    };
    hand1 = {
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

  subtasks = [
    {
      traits = {
        a_positive = true;
        b_positive = true;
      };
      fullScore = 0.5;
      scoringMethod = "sum";
    }
    # fallback
    { fullScore = 0.5; }
  ];

  solutions =
    let
      ac = { score, ... }: score == 1;
      unac = { score, ... }: score == 0;
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
      waUnsigned = {
        src = ./solution/wa-unsigned.20.cpp;
        subtaskPredictions = {
          "0" = ac;
          "1" = unac;
        };
      };
      tle = {
        src = ./solution/tle.20.cpp;
        subtaskPredictions = {
          "0" = tleOrAc;
          "1" = tleOrAc;
        };
        participantVisibility = true;
      };
      mleDynamic = {
        src = ./solution/mle-dynamic.20.cpp;
        subtaskPredictions = {
          "0" = unac;
          "1" = unac;
        };
      };
      mleStatic = {
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
    default = hull.problemTarget.common;
    hydro = hull.problemTarget.hydro {
      statements = {
        en = "statement.en.pdf";
        zh = "statement.zh.pdf";
      };
    };
    lemon = hull.problemTarget.lemon {
      solutionExtNames = lib.mapAttrs (_: _: "cpp") config.solutions;
    };
    uoj = hull.problemTarget.uoj { };
    cms = hull.problemTarget.cms {
      statements = {
        english = "statement.en.pdf";
        chinese = "statement.zh.pdf";
      };
    };
    domjudge = hull.problemTarget.domjudge {
      statement = "statement.en.pdf";
    };

    minimal =
      (
        # Options for the target are defined in a function that returns the attrset.
        {
          solutionFileName ? "std.cpp",
        }:
        {
          _type = "hullProblemTarget";
          __functor =
            self: problem:
            pkgs.runCommandLocal "hull-problemTargetOutput-${problem.name}-minimal" { } ''
              mkdir -p $out/data $out/solution

              # Use the custom option from the `self` argument.
              cp ${problem.mainCorrectSolution.src} $out/solution/${self.solutionFileName}

              # ... (rest of the script is the same)
              ${lib.concatMapStringsSep "\n" (tc: ''
                cp ${tc.data.input} $out/data/${tc.name}.in
                cp ${tc.data.outputs}/output $out/data/${tc.name}.out
              '') (builtins.attrValues problem.testCases)}
            '';

          # The option is now part of the target's attribute set.
          inherit solutionFileName;
        }
      )
        { solutionFileName = "main_solution.cpp"; }; # We can now configure it.
  };
}
