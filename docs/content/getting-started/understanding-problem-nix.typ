#import "/templates/page.typ": page

#show: page.with(
  title: "Understanding problem.nix",
  summary: "Understand how problem.nix defines metadata, programs, test data, scoring, solutions, and targets for one Hull problem.",
)

= Understanding `problem.nix`

`problem.nix` defines one problem.

== Basic Metadata

These options define the fundamental properties of your problem.

```nix
{
  name = "aPlusB";

  displayName.en = "A + B Problem";

  tickLimit = 1000 * 10000000; # 1 second
  memoryLimit = 256 * 1024 * 1024; # 256 MiB
}
```

- `name`: A unique, machine-readable identifier for the problem. It should be a simple string (e.g., `camelCase`) without spaces or special characters. This name is used for directory structures and internal references.
- `displayName`: An attribute set containing human-readable titles for the problem in different languages. The keys are language codes (e.g., `en`, `zh`).
- `tickLimit`: The default execution time limit for solutions, measured in "ticks". A common starting point is `1000 * 10000000` ticks, which roughly corresponds to 1 second of execution time in the WASM runtime.
- `memoryLimit`: The default memory limit for solutions, measured in bytes.

== Core Programs

Hull relies on several key programs to manage the problem's lifecycle. You provide the source code, and Hull handles the compilation and execution within its deterministic environment.

```nix
{
  checker.src = ./checker.23.cpp;

  validator.src = ./validator.23.cpp;

  generators.rand.src = ./generator/rand.23.cpp;
}
```

- `checker`: The program responsible for comparing a solution's output against the standard answer to determine correctness. It can award partial scores.
- `validator`: The program that reads a test case input file and verifies that it conforms to the problem's specified format and constraints. This is a critical step to ensure all test data is valid.
- `generators`: An attribute set of input generators.

== C and C++ Compilation

`hull.language.c` and `hull.language.cpp` are factories. An empty instance uses Hull's defaults. The standard is derived from the source suffix, such as `.17.c` or `.23.cpp`.

```nix
{
  languages =
    hull.language.c { }
    // hull.language.cpp {
      optimize.default = _: "2";
      fastMath.default = _: true;
    };
}
```

Each factory option has `default = context: value;` and `validate = valueExpression: shellCode;` fields. Overrides are merged by field. The context contains `language` (`"c"` or `"cpp"`) and the suffix-derived `standard`.

The supported options are:

- `optimize`: `"0"`, `"1"`, `"2"`, `"3"`, `"g"`, `"s"`, or `"z"`; default `"3"`.
- `standard`: a Clang C or C++ standard, including GNU variants. Prefer a versioned source suffix; set this option for variants such as `"gnu++20"`.
- `stackSize`: executable stack size in bytes; default `67108864`.
- `pageSize`: WebAssembly page size; default `65536`.
- `globalBase`: WebAssembly global base address; default `1024`.
- `standardIncludes`: whether standard include paths are available; default `true`. `false` adds `-nostdinc`.
- `standardLibraries`: whether standard libraries are linked; default `true`. `false` adds `-nostdlib`.
- `freestanding`: whether to compile with `-ffreestanding`; default `false`.
- `fastMath`: whether to compile with `-ffast-math`; default `false`.

`optimize`, `standard`, `standardIncludes`, `freestanding`, and `fastMath` affect object and executable compilation. `stackSize`, `pageSize`, `globalBase`, and `standardLibraries` affect executable linking only.

A source file can override an instantiated factory through its first marked C or C++ comment:

```cpp
/*
 * hull_source_config {
 *   "optimize": "2",
 *   "standard": "gnu++20",
 *   "fastMath": true
 * }
 */
```

The payload must be a JSON object. Values must be strings, booleans, or signed 64-bit integers. Unknown keys, duplicate keys, invalid values, and unsafe text fail compilation. A `// hull_source_config ...` comment must contain its complete JSON payload on one line.

== Test Data

The `testCases` attribute set is where you define every test case for your problem. Each test case can be specified manually or generated programmatically.

```nix
{
  testCases = {
    # Manually provided test case
    manual-1 = {
      inputFile = ./data/1.in;
      groups = [ "sample" ];
    };

    # Generated test case
    random-small = {
      generator = "rand";
      arguments = [ "--n-max=100" ];
    };
  };
}
```

Each attribute in `testCases` defines a test case. The name of the attribute (e.g., `manual-1`) becomes the unique name of the test case.

- `inputFile`: Use this to specify a path to a manually created input file.
- `generator`: Use this to specify the name of a generator (from the `generators` set) to create the input file.
  - `arguments`: A list of command-line arguments to pass to the generator. This allows you to create many different test cases from a single generator program.
- `groups`: A list of strings to categorize the test case. The group `"sample"` is special and indicates that the test case should be treated as a sample for problem statements.

== Subtasks & Scoring

Hull uses a system of "traits" to define subtasks. A trait is a specific property that a test case might have (e.g., "$N <= 100$").

1. First, you declare all possible traits for the problem.
2. The `validator` is responsible for detecting which traits are present in a given input file.
3. Then, you define subtasks based on combinations of these traits.

```nix
{
  # 1. Declare all possible traits
  traits = {
    n_le_100 = {
      descriptions.en = "$N <= 100$.";
    };
    all_positive = {
      descriptions.en = "All numbers are positive.";
    };
  };

  # 2. Define subtasks based on traits
  subtasks = [
    {
      # This subtask requires both traits to be true
      traits = {
        n_le_100 = true;
        all_positive = true;
      };
      fullScore = 0.4; # This subtask is worth 40% of the total score
    },
    {
      # This subtask only requires n_le_100
      traits = {
        n_le_100 = true;
      };
      fullScore = 0.6; # This subtask is worth 60%
    }
  ];
}
```

- `traits`: An attribute set where you declare every trait your problem uses. Each trait can have a `descriptions` for different languages.
- `subtasks`: A list of subtask definitions. Hull automatically assigns test cases to a subtask if they satisfy its `traits` requirements.
  - `traits`: An attribute set specifying the required traits for this subtask.
  - `fullScore`: The score awarded for passing all test cases in this subtask. The total score of the problem is the sum of all subtask scores.

== Solutions

`solutions` lists implementations used for analysis and checks.

```nix
{
  solutions = {
    # The main correct solution
    std = {
      src = ./solution/std.23.cpp;
      mainCorrectSolution = true;
      subtaskPredictions = {
        "0" = { score, ... }: score == 1.0; # Predicts AC on subtask 0
        "1" = { score, ... }: score == 1.0; # Predicts AC on subtask 1
      };
    };

    # A wrong answer solution
    wa = {
      src = ./solution/wa.23.cpp;
      subtaskPredictions = {
        "0" = { score, ... }: score == 1.0; # Predicts AC on subtask 0
        "1" = { score, ... }: score == 0.0; # Predicts WA on subtask 1
      };
    };
  };
}
```

- `mainCorrectSolution`: Exactly one solution must set this to `true`. Hull uses it to generate official outputs.
- `subtaskPredictions`: An attribute set keyed by zero-based subtask indices as strings. Each value is a Nix function that checks the analyzed result.

== Documents & Targets

Documents describe generated files such as statements and reports. Targets describe how Hull packages the analyzed problem.

```nix
{
  documents = {
    "statement.en.pdf" = {
      path = hull.xcpcStatement config {
        statement = ./document/statement/en.typ;
        displayLanguage = "en";
      };
      displayLanguage = "en";
      participantVisibility = true;
    };
  };

  targets = {
    default = hull.problemTarget.common;
    hydro = hull.problemTarget.hydro {
      statements.en = "statement.en.pdf";
    };
    uoj = hull.problemTarget.uoj { };
  };
}
```

- `documents`: generated files such as statements or reports.
- `targets`: packaging formats. `default` is used by `hull build`.
- Some targets are direct targets, such as `hull.problemTarget.common`, `hull.problemTarget.hydro`, and `hull.problemTarget.uoj`.
- Legacy judge-format target families require an explicit branch constructor, such as `hull.problemTarget.legacy.hydro.batch`, `hull.problemTarget.legacy.uoj.stdioInteraction`, or `hull.problemTarget.legacy.cms.answerOnly`.
