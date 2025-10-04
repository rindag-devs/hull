# Hull

[![license][badge.license]][license] [![docs][badge.docs]][docs]

[badge.license]: https://img.shields.io/github/license/rindag-devs/hull
[badge.docs]: https://img.shields.io/github/deployments/rindag-devs/hull/hull%20%28Production%29?label=docs
[license]: https://github.com/rindag-devs/hull/blob/main/COPYING.LESSER
[docs]: https://hull.aberter0x3f.top/

**A Nix-powered framework for creating and judging competitive programming problems with unparalleled determinism.**

Hull provides a complete, hermetic environment for the entire lifecycle of a competitive programming problem — from creation and validation to judging and packaging. By leveraging the power of Nix and WebAssembly, it guarantees that every step of the process is bit-for-bit reproducible, eliminating the "works on my machine" problem common in traditional judging setups.

## Getting Started

Visit the [documentation home page][docs] to learn more.

## Features

- **Declarative Problem Configuration:** Define every aspect of your problem — test cases, subtasks, solutions, checkers, validators, and documents — in a single, comprehensive Nix file.
- **Integrated Toolchain:** Built-in support for validators, checkers, test data generators, and solution analysis.
- **Flexible Judging Logic:** Supports batch problems, interactive problems (via stdio or grader), and answer-only tasks. You can also use a custom judger to implement more flexible judging logic.
- **Automated Sanity Checks:** The framework automatically validates test data, verifies that solution performance matches predictions, and runs tests on your checker and validator to ensure correctness.
- **High-Quality Document Generation:** Uses [Typst](https://typst.app/) to produce professional-grade PDF problem statements from your problem data.

## License

[LGPL-3.0-or-later][license]

Copyright (c) 2025-present, rindag-devs
