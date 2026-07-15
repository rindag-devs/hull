# AGENTS.md

## Project Overview

Hull is a Nix-based framework for competitive programming problem authoring, runtime analysis, and package generation. The codebase combines Rust CLI/runtime code, Nix build logic, Typst document templates, C/C++ test assets, and web documentation assets.

## Development Commands

- Enter the development environment with `nix develop`.
- Format the repository with `just format`.
- Run lint checks with `just lint`.
- Clean build artifacts with `just clean`.
- Update dependencies with `just update`.
- Build one test problem with `just -- problem <name> [args...]`, for example `just -- problem aPlusB --stop-on-failure`.
- Build all test problems with `just -- all-problems [args...]`.

## Rust Rules

- Every Rust `pub` item must have a documentation comment, including public structs, enums, traits, functions, fields, and variants.
- Do not use `pub(crate)` or `pub(super)`. Make an item either fully public with documentation or private.
- Prefer small, direct functions over helper layers that only wrap one operation.
- Prefer typed enums for fixed values instead of string fallbacks.
- Convert external status strings to typed values at the serde boundary.
- Preserve intentional direct user output paths; do not replace command-facing `println!` or `eprintln!` with tracing unless the output is diagnostic logging.

## Documentation And Comments

- Documentation and comments must be concise and durable.
- Avoid time-sensitive words such as `current`, `currently`, `latest`, `new`, `recent`, `now`, and `today`.
- Avoid filler comments that restate the code.
- Use comments to explain non-obvious constraints, invariants, or external behavior.

## Compatibility Policy

- Do not add backward compatibility code unless the task explicitly requires it.
- This project favors removing stale APIs, obsolete behavior, and compatibility shims.
- Prefer a clean breaking change over preserving an unused legacy path.

## Nix And Build Behavior

- Avoid passing large JSON payloads through command-line arguments; use files for large data.
- Preserve reproducible Nix behavior and avoid host-specific assumptions.

## Testing And Verification

- Run `just format` after edits that affect formatted files.
- Run `cargo check` after Rust changes.
- Keep all test names short and meaningful.
- Avoid meaningless tests, such as asserting constant values.

## Repository Hygiene

- Do not revert unrelated worktree changes.
- Do not commit, amend, or push unless the user requests it.
- Keep changes focused on the requested task.
