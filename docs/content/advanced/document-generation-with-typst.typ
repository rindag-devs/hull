#import "/templates/page.typ": page

#show: page.with(
  title: "Document Generation with Typst",
  summary: "Generate Hull problem and contest PDFs with Typst templates driven by serialized build data.",
)

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

```text
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

=== Automatic Sample Visualization <automatic-sample-visualization>

Every embedded sample includes the validator's full reader trace at `samples.#.input-validation.reader-trace-tree`. The standard `hull.xcpcStatement` template recognizes two CPLib tags attached to nodes in this trace:

- `hull/case` is an integer identifying a logical test case. The template gives consecutive cases alternating background colors and labels their first lines, which makes multi-test samples easier to follow.
- `hull/graph` describes a graph or tree. Its `name` is a string and `nodes` is a list of strings. Each edge has string endpoints `u` and `v`, a Boolean `directed` value, and an optional string `w` label. The template renders the graph below the sample.

Attach the tags while reading the corresponding structure in the validator. Full traces are produced for statement samples, so guard additional tag construction by the trace level when it is expensive.

```cpp
if (in.get_trace_level() >= cplib::trace::Level::FULL) {
  in.attach_tag(
      "hull/graph",
      cplib::json::Map{
          {"name", std::format("graph_{}", test_case_index)},
          {"nodes", std::views::iota(1, n + 1) |
                        std::views::transform([](std::int32_t x) {
                          return std::to_string(x);
                        })},
          {"edges", edges |
                        std::views::transform([](const Edge &edge) {
                          return cplib::json::Map{
                              {"u", std::to_string(edge.u)},
                              {"v", std::to_string(edge.v)},
                              {"w", std::to_string(edge.w)},
                              {"directed", false},
                          };
                        })},
      });
  in.attach_tag("hull/case", test_case_index);
}
```

Attach `hull/case` to the reader node that spans one complete test case. Attach `hull/graph` to the node that spans the represented graph; multiple named graphs are rendered in name order. Omit `w` for unweighted edges.

== Generating Contest Booklets

The same principles apply to generating documents for an entire contest. The `cnoiParticipant` target, for example, uses the `hull.document.mkContestTypstDocument` function.

It aggregates all problems into one JSON input for Typst.
