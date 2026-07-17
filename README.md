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

- **Reproducible problem pipelines.** Nix definitions connect programs, generated data, validation, official outputs, solution predictions, documents, and packages in one buildable problem model.
- **First-class [Typst integration](https://hull.aberter0x3f.top/advanced/document-generation-with-typst/).** Build multilingual statements, technical overviews, and contest booklets from analyzed problem data, with automatic samples, subtasks, and validator-backed visualizations.
- **Programmable [judging workflows](https://hull.aberter0x3f.top/advanced/custom-judgers/).** Use built-in batch, interactive, and answer-only models, or define a custom judger for multi-stage evaluation, custom protocols, and specialized scoring.
- **Extensible [problem and contest targets](https://hull.aberter0x3f.top/advanced/problem-and-contest-targets/).** Package for supported judge systems and participant environments, or write a custom target for a project-specific output format.
- **End-to-end parallel execution.** Problem builds, contest builds, judging, and stress testing use available CPU parallelism by default. Artifact builds and packaging retain Nix's own parallel scheduling, allowing high-core-count servers to process large solution and testcase sets with high throughput.
- **[AI-agent-friendly authoring](https://hull.aberter0x3f.top/getting-started/installation-and-setup/#creating-a-new-problem).** Published Agent Skills, `llms.txt`, Typst source mirrors, and generated option references give AI agents structured entry points for creating and maintaining complete Hull problems.

## License

[LGPL-3.0-or-later][license]

Copyright (c) 2025-present, rindag-devs
