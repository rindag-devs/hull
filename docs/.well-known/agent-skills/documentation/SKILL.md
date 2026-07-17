---
name: documentation
description: Discover and consume Hull documentation, including the canonical llms.txt index, sitemap, Typst source mirrors, and generated Nix option references. Use when an agent needs authoritative Hull concepts, configuration fields, defaults, examples, or published documentation sources.
---

# Hull Documentation Discovery

Use this skill to discover and consume the Hull documentation.

## When To Use

Use this skill when you need to understand Hull, a Nix-based framework for competitive programming problem authoring, runtime analysis, and packaging.

## Entry Points

- Start with `https://hull.aberter0x3f.top/llms.txt` for the canonical machine-readable documentation index.
- Use `https://hull.aberter0x3f.top/sitemap.xml` as the authoritative crawl list for published HTML documentation pages.
- Use `https://hull.aberter0x3f.top/reference/problem-options/` and `https://hull.aberter0x3f.top/reference/contest-options/` for exact generated Nix module option references.

## Content Negotiation

- HTML is the default browser representation.
- Send `Accept: text/markdown` to any canonical documentation page to receive the corresponding Typst source with `Content-Type: text/markdown; charset=utf-8`.
- Send `Accept: text/x-typst` to any canonical documentation page to receive the corresponding Typst source with `Content-Type: text/plain; charset=utf-8`.
- Source-oriented responses include `x-agent-source-format: typst`.
- Direct source mirrors are available under `https://hull.aberter0x3f.top/.well-known/agent-typst/`.

## Content Usage Policy

The documentation may be used for search, AI input, and AI training.
