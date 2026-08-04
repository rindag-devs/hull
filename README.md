# Hull

[![license][badge.license]][license] [![ci][badge.ci]][ci] [![docs][badge.docs]][docs]

[badge.license]: https://img.shields.io/github/license/rindag-devs/hull
[badge.ci]: https://img.shields.io/github/actions/workflow/status/rindag-devs/hull/ci.yml?label=ci
[badge.docs]: https://img.shields.io/github/deployments/rindag-devs/hull/production?label=docs
[license]: https://github.com/rindag-devs/hull/blob/main/COPYING.LESSER
[ci]: https://github.com/rindag-devs/hull/blob/main/.github/workflows/ci.yml
[docs]: https://hull.aberter0x3f.top/

**A Nix-based framework for competitive programming problem authoring, analysis, and packaging.**

## Getting Started

Visit the [documentation home page][docs] to learn more.

## Features

Hull treats a problem as one reproducible pipeline rather than a collection of scripts.

- **Reproducible problem pipelines.** Nix definitions connect programs, generated data, validation, official outputs, solution predictions, documents, and packages in one buildable problem model. A build checks the relationships between them. It does not merely compile files.
- **Deterministic WASIp1 execution.** Hull runs authoritative source WASM with explicit tick, memory, filesystem, standard-stream, and per-resource file-size contracts, including deterministic multi-program interaction.
- **Data-driven [Typst documents](https://hull.aberter0x3f.top/advanced/document-generation-with-typst/).** Generate multilingual statements, technical overviews, and contest booklets from analyzed problem data. Templates can inject samples and subtasks. They can render validator-backed visualizations.
- **Programmable [judging](https://hull.aberter0x3f.top/advanced/custom-judgers/).** Start with batch, standard-input/standard-output interaction, or answer-only judging. Define a custom judger when a problem needs multiple evaluation stages, a specialized protocol, or custom scoring.
- **Targets are an [extension point](https://hull.aberter0x3f.top/advanced/problem-and-contest-targets/).** Package a problem or contest for supported judge systems and participant environments. Define a target for a project-specific directory, archive, or deployment format when needed.
- **End-to-end parallel execution.** Hull uses available CPU parallelism by default across problem builds, contest builds, judging, and stress testing. Artifact builds and final packaging retain Nix's own parallel scheduling. This lets high-core-count servers process large solution and testcase sets with high throughput.
- **Designed for [AI agents](https://hull.aberter0x3f.top/getting-started/installation-and-setup/#creating-a-new-problem).** Hull publishes Agent Skills, `llms.txt`, Typst source mirrors, and generated Nix option references. An agent can use these machine-readable entry points to discover exact configuration. It can also follow a complete problem-authoring workflow.

## License

[LGPL-3.0-or-later][license]

Copyright (c) 2025-present, rindag-devs

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and the [Hull Contributor Licence Agreement](CLA.md) that applies to submitted contributions.
