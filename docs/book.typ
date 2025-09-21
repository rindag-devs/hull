#import "@preview/shiroa:0.2.3": *

#show: book

#book-meta(
  title: "Hull",
  description: "Hull Documentation",
  authors: ("rindag-devs",),
  language: "en",
  summary: [
    #prefix-chapter("src/introduction.typ")[Introduction]

    = Getting Started
    - #chapter("src/getting-started/installation-and-setup.typ")[Installation & Setup]
    - #chapter("src/getting-started/basic-workflow.typ")[Basic Workflow]
    - #chapter("src/getting-started/understanding-problem-nix.typ")[Understanding `problem.nix`]
    - #chapter("src/getting-started/understanding-contest-nix.typ")[Understanding `contest.nix`]
    - #chapter("src/getting-started/best-practices-and-conventions.typ")[Best Practices & Conventions]

    = Advanced
    - #chapter("src/advanced/custom-judgers.typ")[Custom Judgers]
    - #chapter("src/advanced/problem-and-contest-targets.typ")[Problem & Contest Targets]
    - #chapter("src/advanced/document-generation-with-typst.typ")[Document Generation with Typst]
  ],
)

// re-export page template
#import "templates/page.typ": project
#let book-page = project
