#import "../book.typ": book-page

#show: book-page.with(title: "Document Generation with Typst")

= Document Generation with Typst

Hull uses #link("https://typst.app/")[Typst] to generate PDFs from problem or contest data.

== How it Works

1. *Declaration in `problem.nix`*: You define documents within the `documents` attribute set. Each entry maps an output filename to a document definition. The `path` attribute of this definition is assigned a document-generating function, such as the built-in `hull.xcpcStatement` helper.

  ```nix
  # In problem.nix
  {
    # ... other problem options

    documents = {
      "statement.en.pdf" = {
        # The `path` attribute points to the final PDF derivation.
        path = hull.xcpcStatement config {
          # Path to the Typst file containing the problem's narrative.
          statement = ./document/statement/en.typ;
          # Tell the template which language to render.
          displayLanguage = "en";
        };
        displayLanguage = "en";
        participantVisibility = true;
      };
    };

    # ...
  }
  ```

2. *Data Serialization*: Hull serializes problem or contest data into `hull-generated.json`.

3. *Typst Compilation*: Hull invokes the Typst compiler with a pre-configured template (provided by `hull.xcpcStatement`). It passes the path to the generated `hull-generated.json` as an input to the template.

4. *Rendering*: The Typst template reads `hull-generated.json` and renders the PDF.

The PDF uses the same generated data as the build.

== Customizing the Template

Use `hull.xcpcStatement` to render a standard statement.

```plain
document/
└── statement/
    └── en.typ
```

The `en.typ` file does not contain any layout logic. It simply defines a set of variables that the `hull.xcpcStatement` template will use to populate the document.

```typst
// In document/statement/en.typ

#let description = [
  You are given two integers $A$ and $B$. Your task is to calculate the sum of these two integers.
]

#let input = [
  The first line of the input contains two integers $A$ and $B$ ($-10^3 <= A, B <= 10^3$).
]

#let output = [
  Output a single line contains a single integer, indicating the answer.
]

#let notes = none // Or provide content for the "Notes" section
```

Add more languages by adding more statement files. Use a custom document function if needed.

== The `hull-generated.json` Data Structure

The `hull-generated.json` file is the bridge between your Nix configuration and your Typst template. Understanding its structure allows you to fully leverage the available data. Below is a simplified overview of its contents.

```json
{
  // Basic problem metadata
  "name": "aPlusB",
  "display-name": { "en": "A + B Problem" },
  "tick-limit": 1000000000,
  "memory-limit": 16777216,
  "full-score": 1.0,

  // List of all declared traits
  "traits": [
    [ "a_positive", { "descriptions": { "en": "$A$ is a positive integer." } } ],
    [ "b_positive", { "descriptions": { "en": "$B$ is a positive integer." } } ]
  ],

  // List of all subtasks
  "subtasks": [
    {
      "full-score": 0.5,
      "traits": { "a_positive": true, "b_positive": true },
      "test-cases": [ "rand1", "hand1" ] // Names of test cases in this subtask
    },
    // ...
  ],

  // List of sample cases (from test cases in the "sample" group)
  "samples": [
    {
      "input": "1 2\n",
      "outputs": { "output": "3\n" },
      "input-validation": {
        "status": "valid",
        "reader-trace-tree": { /* ... detailed parse tree ... */ },
        // ... other values
      }
    }
  ]
  // ... and much more, including detailed solution analysis.
}
```

Templates can render subtasks, samples, and generated metadata directly.

=== Automatic Visualization

The `samples.#.input-validation.reader-trace-tree` object contains the validator parse tree.

By attaching special tags within your validator code (using `cplib`), you can embed structured information directly into this tree. For example, for a graph problem, you can tag the nodes and edges.

```cpp
// In your problem's header file or validator.cpp
// ... inside a cplib var::Reader scope ...

in.attach_tag("hull/graph", cplib::json::Value(cplib::json::Map{
  {"name", cplib::json::Value("graph")},
  {"nodes", cplib::json::Value(/* vector of node name strings */)},
  {"edges", cplib::json::Value(/* vector of edge objects */)},
}));
```

`hull.xcpcStatement` can render graph visualizations from `hull/graph` tags.

== Generating Contest Booklets

The same principles apply to generating documents for an entire contest. The `cnoiParticipant` target, for example, uses the `hull.document.mkContestTypstDocument` function.

It aggregates all problems into one JSON input for Typst.
