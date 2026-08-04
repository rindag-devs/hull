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

- All natural-language documentation in English must follow ASD-STE100 Simplified Technical English. This applies to documentation, skills, the README, and all other prose.
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

# ASD-STE100

When you write technical text (documentation, READMEs, runbooks, procedures, error messages, release notes, reports), obey these rules from ASD-STE100 Simplified Technical English:

- CLASSIFY FIRST. Procedural text tells the reader what to do: imperative mood, maximum 20 words per sentence, one instruction per sentence. Descriptive text explains: simple tenses, maximum 25 words per sentence, one topic per paragraph, maximum six sentences per paragraph. Never mix the two in one passage.
- VERBS. Use only: infinitive, imperative, simple present, simple past, simple future, past participle as adjective. No present perfect ("has completed" -> "completed"). No "-ing" verb forms ("making it easy" -> new sentence). Active voice; passive only in descriptions when the agent is unknown. Approved modals: can, will, must. Banned: should, would, may, might, could. For "should": write "must" if required, delete if optional.
- SENTENCES. Keep complete grammar: no contractions, keep articles, keep "that" ("make sure that the file exists"). Put conditions before commands, with a comma: "If the test fails, read the log." No semicolons - write two sentences. Use a vertical list for more than two items or steps.
- WORDS. One word, one meaning, for the whole document: pick one of check/verify/confirm and keep it. Noun chains of maximum three words; break longer ones with prepositions ("the timeout value for the connection pool"). Delete words that carry no fact: simply, seamlessly, robust, powerful, comprehensive, leverage, "in order to", "it is worth noting". Replace: utilize -> use, prior to -> before, in the event that -> if, e.g. -> for example. American spelling.
- WARNINGS. Command or condition first, then the risk: "Do not run this against production. The command deletes rows."
- NEVER TOUCH. Code blocks, identifiers, CLI commands, file paths, quoted error messages, product names. Each counts as one word toward sentence limits.
- SELF-CHECK before returning: scan for contractions, "has been", "should", ", making", semicolons. Count words in your three longest sentences and split any over the limit. Collapse synonym rotation.

Do not apply these rules to marketing copy or brand writing.
