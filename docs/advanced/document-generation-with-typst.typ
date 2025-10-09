#import "../book.typ": book-page

#show: book-page.with(title: "Document Generation with Typst")

= Document Generation with Typst

Hull leverages the powerful, modern typesetting system #link("https://typst.app/")[Typst] to produce high-quality, professional-grade PDF documents, such as problem statements and technical overviews. This integration is designed to be both robust and highly customizable, following a data-driven approach that separates a problem's technical specification from its visual presentation.

== How it Works

The core of Hull's document generation system is the declarative definition within your `problem.nix` file. The process ensures that your documents are always perfectly synchronized with your problem's configuration.

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

2. *Data Serialization*: When you run `hull build`, Hull first evaluates your complete `problem.nix`. It then gathers all relevant data—such as `name`, `displayName`, `tickLimit`, `memoryLimit`, `subtasks`, and sample test cases—and serializes it into a structured JSON file named `hull-generated.json`.

3. *Typst Compilation*: Hull invokes the Typst compiler with a pre-configured template (provided by `hull.xcpcStatement`). Crucially, it passes the path to the newly created `hull-generated.json` as an input to the template.

4. *Rendering*: The Typst template reads the `hull-generated.json` file and uses the data within it to dynamically render the final PDF, combining technical data with the narrative content you provided.

This workflow guarantees that your problem statement is a direct reflection of its technical definition. If you change a subtask score or a memory limit in `problem.nix`, the PDF will be automatically updated with the new values on the next build, eliminating any possibility of inconsistency.

== Customizing the Template

Hull's philosophy is to abstract away boilerplate. Instead of requiring you to build a Typst template from scratch, it provides high-level helpers like `hull.xcpcStatement` that handle all the layout and styling for you.

Your only task is to provide the narrative content for the problem. The official Hull template provides a simple structure for this:

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

This modular design makes it straightforward to add support for new languages (by creating `{lang}.typ`) or to focus purely on the problem's content without worrying about visual presentation. For advanced customization, you can create your own document-generating function instead of using `hull.xcpcStatement`.

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

With this data, you can programmatically generate tables for subtasks, display sample cases, and ensure that all technical details in your problem statement are accurate and automatically updated.

=== Automatic Visualization

The `samples.#.input-validation.reader-trace-tree` object contains a detailed parse tree generated by the validator. This powerful feature allows the Typst template to understand the structure of your sample data.

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

The `hull.xcpcStatement` template automatically detects `hull/graph` tags and uses them to render a graph visualization for the corresponding sample case, right in the PDF. This provides a clear and helpful visual aid for contestants in problems involving graphs, trees, or other complex structures, with no extra effort required in the Typst file.

== Generating Contest Booklets

The same principles apply to generating documents for an entire contest. The `cnoiParticipant` target, for example, uses the `hull.document.mkContestTypstDocument` function.

This function works similarly to its problem-level counterpart but aggregates data from *all* problems within the contest. It produces a single JSON file containing an array of problem data objects. A specialized Typst template can then iterate over this array to generate a comprehensive PDF booklet containing all problem statements, a table of contents, and consistent styling, perfect for distributing to contestants.
