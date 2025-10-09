#import "../book.typ": book-page

#show: book-page.with(title: "Document Generation with Typst")

= Document Generation with Typst

Hull leverages the powerful, modern typesetting system #link("https://typst.app/")[Typst] to produce high-quality, professional-grade PDF documents, such as problem statements and technical overviews. This integration is designed to be both robust and highly customizable, following a data-driven approach that separates a problem's technical specification from its visual presentation.

== How it Works

The core of Hull's document generation system is the declarative definition within your `problem.nix` file. The process ensures that your documents are always perfectly synchronized with your problem's configuration.

1. *Declaration in `problem.nix`*: You define documents within the `documents` attribute set. Each entry maps an output filename to a document-generating function, typically `hull.document.mkProblemTypstDocument`.

  ```nix
  # In problem.nix
  {
    # ... other problem options

    documents = {
      "statement.en.pdf" = hull.document.mkProblemTypstDocument config {
        # Path to the directory containing your Typst source files.
        src = ./document/statement;

        # Pass custom inputs to the Typst template.
        # Here, we tell the template to render in English.
        inputs = { language = "en"; };
      };
    };

    # ...
  }
  ```

2. *Data Serialization*: When you run `hull build`, Hull first evaluates your complete `problem.nix`. It then gathers all relevant data—such as `name`, `displayName`, `tickLimit`, `memoryLimit`, `subtasks`, and sample test cases—and serializes it into a structured JSON file named `hull-generated.json`.

3. *Typst Compilation*: Hull invokes the Typst compiler, providing it with your template's entry point (e.g., `main.typ` from the `src` directory). Crucially, it passes the path to the newly created `hull-generated.json` as an input to the template.

4. *Rendering*: The Typst template reads the `hull-generated.json` file and uses the data within it to dynamically render the final PDF.

This workflow guarantees that your problem statement is a direct reflection of its technical definition. If you change a subtask score or a memory limit in `problem.nix`, the PDF will be automatically updated with the new values on the next build, eliminating any possibility of inconsistency.

== Customizing the Template

The official Hull template provides a well-organized directory structure for your Typst documents, designed for clarity and easy customization.

```plain
document/
└── statement/
    ├── main.typ
    ├── problem/
    │   └── en.typ
    └── translation/
        └── en.typ
```

The roles of these files are:
- `main.typ`: This is the main entry point and layout controller. Its primary job is to load the `hull-generated.json` data, import the necessary language-specific files, and define the overall structure and style of the document (e.g., fonts, colors, table layouts). *Modify this file to change the visual style.*
- `problem/en.typ`: This file contains the narrative content of your problem statement for a specific language, such as the problem description, input/output format, and any special notes. *Modify this file to change the problem's text.*
- `translation/en.typ`: This file provides translations for static UI text within the template, such as "Input Format", "Memory Limit", or "Subtasks". This makes it easy to internationalize your statement's chrome.

The `main.typ` file orchestrates everything by loading data and dynamically importing the correct content files based on the `inputs` you provided in `problem.nix`.

```typst
// In document/statement/main.typ

// Get the path to the JSON file passed by Hull.
#let hull-generated-json-path = get-input-or-default(
  "hull-generated-json-path",
  "hull-generated.example.json", // A fallback for local development
)
// Load and parse the JSON data.
#let hull = json(hull-generated-json-path)

// Get the language from the `inputs` map in problem.nix.
#let language = get-input-or-default("language", "en")

// Dynamically import the correct content and translation files.
#import "problem/" + language + ".typ" as statement
#import "translation/" + language + ".typ" as translation

// Call a master function to render the entire document.
#render-problem(hull, statement, translation, language)
```

This modular design makes it straightforward to add support for new languages or to completely redesign the visual theme without altering the problem's core textual content.

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
    {
      "full-score": 0.5,
      "traits": {},
      "test-cases": [ "rand1", "rand2", "rand3", "hand1" ]
    }
  ],

  // List of sample cases (from test cases in the "sample" group)
  "samples": [
    {
      "input": "1 2\n",
      "outputs": {
        "output": "3\n"
      }
    }
  ]
  // ... and much more, including detailed solution analysis.
}
```

With this data, you can programmatically generate tables for subtasks, display sample cases, and ensure that all technical details in your problem statement are accurate and automatically updated.

== Generating Contest Booklets

The same principles apply to generating documents for an entire contest. The `cnoiParticipant` target, for example, uses the `hull.document.mkContestTypstDocument` function.

This function works similarly to its problem-level counterpart but aggregates data from *all* problems within the contest. It produces a single JSON file containing an array of problem data objects. A specialized Typst template can then iterate over this array to generate a comprehensive PDF booklet containing all problem statements, a table of contents, and consistent styling, perfect for distributing to contestants.
