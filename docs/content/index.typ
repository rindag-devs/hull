#import "/templates/page.typ": page

#show: page.with(
  title: "Hull Documentation",
  summary: "A practical guide to using Hull for competitive programming problem authoring, analysis, and packaging.",
)

= Introduction

Hull is a Nix-based framework for competitive programming problem authoring, analysis, and packaging.

== What is Hull?

Hull defines problems and contests in Nix, compiles programs to WebAssembly, runs analysis through the Hull CLI, and packages results for judge systems or local inspection.

- Nix defines build inputs and package structure.
- WebAssembly provides a stable execution target.
- Hull CLI performs runtime analysis and packaging.

== Why Hull?

Hull treats a problem as one reproducible pipeline rather than a collection of scripts. A Nix definition connects programs, generated data, validation, official outputs, solution predictions, documents, and packages, so a build checks the relationships between them instead of merely compiling files.

- *Data-driven Typst documents*: Generate multilingual statements, technical overviews, and contest booklets from analyzed problem data. Templates can inject samples and subtasks and render validator-backed visualizations. See #link("/advanced/document-generation-with-typst/")[Document Generation with Typst].
- *Programmable judging*: Start with batch, standard-input/standard-output interaction, or answer-only judging. Define a custom judger when a problem needs multiple evaluation stages, a specialized protocol, or custom scoring. See #link("/advanced/custom-judgers/")[Custom Judgers].
- *Targets are an extension point*: Package a problem or contest for supported judge systems and participant environments, or define a target for a project-specific directory, archive, or deployment format. See #link("/advanced/problem-and-contest-targets/")[Problem and Contest Targets].
- *End-to-end parallel execution*: Hull uses available CPU parallelism by default across problem builds, contest builds, judging, and stress testing. Artifact builds and final packaging retain Nix's own parallel scheduling, allowing high-core-count servers to process large solution and testcase sets with high throughput.
- *Designed for AI agents*: Hull publishes Agent Skills, `llms.txt`, Typst source mirrors, and generated Nix option references. These machine-readable entry points let an agent discover exact configuration and follow a complete problem-authoring workflow. See #link("/getting-started/installation-and-setup/#creating-a-new-problem")[Creating a New Problem].
