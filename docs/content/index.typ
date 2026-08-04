#import "/templates/page.typ": page

#show: page.with(
  title: "Hull Documentation",
  summary: "A practical guide to using Hull for competitive programming problem authoring, analysis, and packaging.",
)

= Introduction

Hull is a Nix-based framework for competitive programming problem authoring, analysis, and packaging.

== What is Hull?

Hull defines problems and contests in Nix. It compiles programs to WASI Preview 1 source WASM. It runs them through a deterministic Wasmtime-backed runner. It packages analyzed results for judge systems or local inspection.

- Nix defines build inputs and package structure.
- WASI Preview 1 source WASM provides the authoritative execution input.
- Hull CLI performs runtime analysis and packaging.

== Why Hull?

Hull treats a problem as one reproducible pipeline rather than a collection of scripts.

- *Reproducible problem pipelines*: Nix definitions connect programs, generated data, validation, official outputs, solution predictions, documents, and packages in one buildable problem model. A build checks the relationships between them. It does not merely compile files.
- *Deterministic WASIp1 execution*: Hull runs authoritative source WASM with explicit tick, memory, filesystem, standard-stream, and per-resource file-size contracts, including deterministic multi-program interaction.
- *Data-driven Typst documents*: Generate multilingual statements, technical overviews, and contest booklets from analyzed problem data. Templates can inject samples and subtasks. They can render validator-backed visualizations. See #link("/advanced/document-generation-with-typst/")[Document Generation with Typst].
- *Programmable judging*: Start with batch, standard-input/standard-output interaction, or answer-only judging. Define a custom judger when a problem needs multiple evaluation stages, a specialized protocol, or custom scoring. See #link("/advanced/custom-judgers/")[Custom Judgers].
- *Targets are an extension point*: Package a problem or contest for supported judge systems and participant environments. Define a target for a project-specific directory, archive, or deployment format when needed. See #link("/advanced/problem-and-contest-targets/")[Problem and Contest Targets].
- *End-to-end parallel execution*: Hull uses available CPU parallelism by default across problem builds, contest builds, judging, and stress testing. Artifact builds and final packaging retain Nix's own parallel scheduling. This lets high-core-count servers process large solution and testcase sets with high throughput.
- *Designed for AI agents*: Hull publishes Agent Skills, `llms.txt`, Typst source mirrors, and generated Nix option references. An agent can use these machine-readable entry points to discover exact configuration. It can also follow a complete problem-authoring workflow. See #link("/getting-started/installation-and-setup/#creating-a-new-problem")[Creating a New Problem].
