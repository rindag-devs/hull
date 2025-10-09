#import "../book.typ": book-page

#show: book-page.with(title: "Understanding problem.nix")

= Understanding `problem.nix`

The `problem.nix` file is the heart of every Hull project. It is a single, declarative file where you define every aspect of your competitive programming problem, from its name and resource limits to its test data, subtasks, and solutions. This chapter provides a comprehensive overview of the essential options within this file.

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
  checker.src = ./checker.20.cpp;

  validator.src = ./validator.20.cpp;

  generators.rand.src = ./generator/rand.20.cpp;
}
```

- `checker`: The program responsible for comparing a solution's output against the standard answer to determine correctness. It can award partial scores.
- `validator`: The program that reads a test case input file and verifies that it conforms to the problem's specified format and constraints. This is a critical step to ensure all test data is valid.
- `generators`: An attribute set of programs used to generate test case inputs. Each attribute in the set defines a new generator (e.g., `generators.rand`).

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

Each attribute in `testCases` defines a new test case. The name of the attribute (e.g., `manual-1`) becomes the unique name of the test case.

- `inputFile`: Use this to specify a path to a manually created input file.
- `generator`: Use this to specify the name of a generator (from the `generators` set) to create the input file.
  - `arguments`: A list of command-line arguments to pass to the generator. This allows you to create many different test cases from a single generator program.
- `groups`: A list of strings to categorize the test case. The group `"sample"` is special and indicates that the test case should be treated as a sample for problem statements.

== Subtasks & Scoring

Hull uses a system of "traits" to define subtasks. A trait is a specific property that a test case might have (e.g., "the input number N is small").

1. First, you declare all possible traits for the problem.
2. The `validator` is responsible for detecting which traits are present in a given input file.
3. Then, you define subtasks based on combinations of these traits.

```nix
{
  # 1. Declare all possible traits
  traits = {
    n_is_small = {
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
        n_is_small = true;
        all_positive = true;
      };
      fullScore = 0.4; # This subtask is worth 40% of the total score
    },
    {
      # This subtask only requires n_is_small
      traits = {
        n_is_small = true;
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

The `solutions` set is where you list all known implementations for the problem, including the standard correct solution, brute-force solutions, and various incorrect solutions. This is crucial for testing and validation.

```nix
{
  solutions = {
    # The main correct solution
    std = {
      src = ./solution/std.20.cpp;
      mainCorrectSolution = true;
      subtaskPredictions = {
        "0" = { score, ... }: score == 1.0; # Predicts AC on subtask 0
        "1" = { score, ... }: score == 1.0; # Predicts AC on subtask 1
      };
    };

    # A wrong answer solution
    wa = {
      src = ./solution/wa.20.cpp;
      subtaskPredictions = {
        "0" = { score, ... }: score == 1.0; # Predicts AC on subtask 0
        "1" = { score, ... }: score == 0.0; # Predicts WA on subtask 1
      };
    };
  };
}
```

- `mainCorrectSolution`: A boolean flag that *must be set to `true` for exactly one solution*. This solution is considered the canonical one and is used to generate the standard answer files for all test cases.
- `subtaskPredictions`: This is a powerful validation feature. It's an attribute set where keys are subtask indices (as strings, e.g., `"0"`, `"1"`) and values are Nix functions. Each function takes a result (containing `score` and `statuses`) and returns `true` if the solution's performance matches your expectation. When you run `hull build`, the framework automatically judges all solutions and verifies that these predictions hold, catching inconsistencies early.

== Documents & Targets

Finally, you can define how to generate documents and package the final problem.

```nix
{
  documents = {
    "statement.en.pdf" = hull.document.mkProblemTypstDocument config {
      src = ./document/statement;
      inputs = { language = "en"; };
    };
  };

  targets = {
    default = hull.problemTarget.common;
    hydro = hull.problemTarget.hydro { /* Hydro-specific options */ };
    uoj = hull.problemTarget.uoj { /* UOJ-specific options */ };
  };
}
```

- `documents`: An attribute set for generating documents. The example shows how to create a PDF problem statement from a Typst template using `hull.document.mkProblemTypstDocument`.
- `targets`: Defines different packaging formats for the problem. A target specifies how to structure the final output directory to be compatible with various online judge systems. Hull provides built-in targets like `common`, `hydro`, and `uoj`. The `default` target is the one built by the `hull build` command.
