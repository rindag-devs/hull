# Hull

[![license][badge.license]][license]

[badge.license]: https://img.shields.io/github/license/rindag-devs/hull
[license]: https://github.com/rindag-devs/hull/blob/main/COPYING.LESSER

**A Nix-powered framework for creating and judging competitive programming problems with unparalleled determinism.**

Hull provides a complete, hermetic environment for the entire lifecycle of a competitive programming problem — from creation and validation to judging and packaging. By leveraging the power of Nix and WebAssembly, it guarantees that every step of the process is bit-for-bit reproducible, eliminating the "works on my machine" problem common in traditional judging setups.

## Getting Started

### Prerequisites

You must have [Nix](https://nixos.org/download.html) installed with Flakes support enabled.

### Creating a New Problem

The easiest way to start a new problem is by using the official Hull flake template.

1.  **Initialize the project from the template:**

    ```bash
    # This will create a new project in the 'my-problem' directory
    nix flake new -t github:rindag-devs/hull --refresh ./my-problem

    # Or use an existing directory
    nix flake init -t github:rindag-devs/hull --refresh
    ```

2.  **Enter the development environment:**
    ```bash
    cd my-problem
    nix develop
    ```
    This command launches a shell with the `hull` CLI and all necessary compilers and tools available in your `PATH`.

## Basic Workflow

Inside the development shell (`nix develop`), you can use the `hull` command-line interface.

### Building the Problem Package

To validate your entire problem configuration and build the final package (containing test data, documents, etc.), run:

```bash
hull build
```

This command evaluates `problem.nix`, runs all automated checks (e.g., validator tests, solution predictions), and builds the default target. The output will be available in a symlink named `result`.

### Judging a Solution

To judge a single solution file against the test cases defined in `problem.nix`, use the `judge` command:

```bash
hull judge path/to/your/solution.cpp
```

For example, to judge the standard correct solution provided in the template:

```bash
hull judge solution/std.20.cpp
```

This will compile the solution, run it against all test cases, and print a detailed report of the results, including scores, statuses, and resource usage.

## Core Philosophy: Nix + WebAssembly

Traditional judging systems are susceptible to inconsistencies arising from different operating systems, compiler versions, library ABIs, and hardware. Hull solves this by combining two powerful technologies:

- **Nix for Reproducible Builds:** Nix provides a purely functional package manager that builds every component in a sandboxed, isolated environment. This ensures that the compiler, libraries, and all dependencies are pinned to exact versions, guaranteeing that the compilation of a solution, checker, or validator will produce the _exact same binary_ on any machine.

- **WebAssembly (WASM) for Deterministic Execution:** Instead of native binaries, all programs are compiled to a standardized WASM target. These WASM modules are then executed within a secure, sandboxed runtime (`wasmtime`). This runtime abstracts away the underlying OS and hardware, providing a consistent execution environment. It enforces strict, deterministic limits on resources like CPU ticks (fuel) and memory, ensuring that a program's behavior and resource consumption are identical across all platforms.

The synergy of Nix and WASM provides a level of determinism and security that is difficult to achieve with conventional tools, ensuring fair and absolutely stable judging results.

## Features

- **Declarative Problem Configuration:** Define every aspect of your problem — test cases, subtasks, solutions, checkers, validators, and documents — in a single, comprehensive Nix file.
- **Integrated Toolchain:** Built-in support for validators, checkers, test data generators, and solution analysis.
- **Flexible Judging Logic:** Supports batch problems, interactive problems (via stdio or grader), and answer-only tasks. You can also use a custom judger to implement more flexible judging logic.
- **Automated Sanity Checks:** The framework automatically validates test data, verifies that solution performance matches predictions, and runs tests on your checker and validator to ensure correctness.
- **High-Quality Document Generation:** Uses [Typst](https://typst.app/) to produce professional-grade PDF problem statements from your problem data.

## License

[LGPL-3.0-or-later][license]

Copyright (c) 2025-present, rindag-devs
