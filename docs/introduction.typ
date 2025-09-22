#import "book.typ": book-page

#show: book-page.with(title: "Introduction")

= Introduction

Welcome to the documentation for #link("https://github.com/rindag-devs/hull")[Hull], a Nix-powered framework for creating and judging competitive programming problems with unparalleled determinism. This document will guide you from the basic setup to advanced customization, enabling you to build robust and perfectly reproducible programming problems and contests.

== What is Hull?

At its core, Hull is a comprehensive, hermetic framework designed to manage the entire lifecycle of a competitive programming problem—from creation and validation to judging and packaging. Its foundational philosophy is built on the synergy of two powerful technologies: Nix and WebAssembly.

*Nix + WebAssembly = Ultimate Determinism.*

This combination is the key to Hull's ability to guarantee that every step of the problem-solving and judging process is bit-for-bit reproducible, eliminating the inconsistencies that plague traditional judging systems.

- *Nix for Reproducible Builds:* Nix provides a purely functional package manager that builds every component—compilers, libraries, and tools—in a sandboxed, isolated environment. This ensures that the compilation of a solution, checker, or validator will produce the _exact same binary_ on any machine, regardless of the host system's configuration.

- *WebAssembly (WASM) for Deterministic Execution:* Instead of native binaries, all programs are compiled to a standardized WebAssembly (WASM) target. These WASM modules are then executed within a secure, sandboxed runtime (`wasmtime`) that abstracts away the underlying OS and hardware. This runtime enforces strict, deterministic limits on resources like CPU ticks (referred to as "fuel") and memory, ensuring that a program's behavior and resource consumption are identical across all platforms.

The synergy of Nix and WebAssembly provides a level of determinism and security that is difficult to achieve with conventional tools, ensuring fair and absolutely stable judging results.

== Why Hull?

Traditional judging systems are susceptible to inconsistencies arising from different operating systems, compiler versions, library Application Binary Interfaces (ABIs), and even subtle hardware differences. Hull is engineered to solve these fundamental problems.

- *Absolute Determinism:* Eliminate the "works on my machine" problem entirely. By controlling both the build environment (with Nix) and the execution environment (with WebAssembly), Hull guarantees that a solution will produce the exact same output and resource usage every time, on any machine.

- *Declarative Configuration:* Define every aspect of your problem—test cases, subtasks, solutions, checkers, validators, and documents—in a single, comprehensive Nix file (`problem.nix`). This declarative approach makes problem configuration transparent, version-controllable, and easy to reason about.

- *Integrated Toolchain:* Hull provides built-in support for validators, checkers, test data generators, and solution analysis. All these components run within the same reproducible environment, ensuring consistency throughout the entire problem development workflow.

- *Security and Stability through Sandboxing:* All user-submitted code, as well as problem components, are executed as WASM modules within a secure sandbox. This prevents unintended side effects, enforces strict resource limits, and guarantees stable judging without compromising the host system.

Whether you are a contest organizer aiming for maximum fairness or a problem setter seeking a streamlined and reliable workflow, Hull provides the tools to achieve your goals with confidence.
