#import "book.typ": book-page

#show: book-page.with(title: "Introduction")

= Introduction

Hull is a Nix-based framework for competitive programming problem authoring, analysis, and packaging.

== What is Hull?

Hull defines problems and contests in Nix, compiles programs to WebAssembly, runs analysis through the Hull CLI, and packages results for judge systems or local inspection.

- Nix defines build inputs and package structure.
- WebAssembly provides a stable execution target.
- Hull CLI performs runtime analysis and packaging.

== Why Hull?

- One file defines problem structure, data, programs, solutions, documents, and targets.
- Analysis checks validator tests, checker tests, official outputs, and solution predictions.
- Targets package one problem or one contest for a specific format.
- The same source tree can package for multiple target systems.
