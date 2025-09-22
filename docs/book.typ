#import "@preview/shiroa:0.2.0": *

#show: book

#book-meta(
  title: "Hull",
  description: "Hull Documentation",
  authors: ("rindag-devs",),
  repository: "https://github.com/rindag-devs/hull",
  repository-edit: "https://github.com/rindag-devs/hull/edit/main/docs/{path}",
  language: "en",
  summary: [
    #prefix-chapter("introduction.typ")[Introduction]

    = Getting Started
    - #chapter("getting-started/installation-and-setup.typ")[Installation & Setup]
    - #chapter("getting-started/basic-workflow.typ")[Basic Workflow]
    - #chapter("getting-started/understanding-problem-nix.typ")[Understanding `problem.nix`]
    - #chapter("getting-started/understanding-contest-nix.typ")[Understanding `contest.nix`]
    - #chapter("getting-started/best-practices-and-conventions.typ")[Best Practices & Conventions]

    = Advanced
    - #chapter("advanced/custom-judgers.typ")[Custom Judgers]
    - #chapter("advanced/problem-and-contest-targets.typ")[Problem & Contest Targets]
    - #chapter("advanced/document-generation-with-typst.typ")[Document Generation with Typst]
  ],
)

// re-export page template
#import "templates/page.typ": project
#let book-page = project
