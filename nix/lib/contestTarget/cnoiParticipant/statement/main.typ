/*
  This file is part of Hull.

  Hull is free software: you can redistribute it and/or modify it under the terms of the GNU
  Lesser General Public License as published by the Free Software Foundation, either version 3 of
  the License, or (at your option) any later version.

  Hull is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
  the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser
  General Public License for more details.

  You should have received a copy of the GNU Lesser General Public License along with Hull. If
  not, see <https://www.gnu.org/licenses/>.
*/

#import "@preview/titleize:0.1.1": titlecase
#import "@preview/diagraph:0.3.6"

#let get-input-or-default(name, default) = {
  if sys.inputs.keys().contains(name) {
    sys.inputs.at(name)
  } else {
    default
  }
}

#let hull-generated-json-path = get-input-or-default(
  "hull-generated-json-path",
  "hull-generated.example.json",
)
#let render-json-path = get-input-or-default(
  "render-json-path",
  "render.example.json",
)
#let hull = json(hull-generated-json-path)
#let render = json(render-json-path)

#let language = get-input-or-default("language", "zh")

// State to control the visibility of the header.
#let show-header = state("show-header", false)

// State to control the visibility of the footer.
#let show-footer = state("show-footer", false)

// State to hold the title of the current problem being rendered.
// The header will read from this state to display the correct problem title.
#let current-problem-title = state("current-problem-title", "")

#show "。": "．"

#let fonts = (
  mono: "IBM Plex Mono",
  mono-bold: "IBM Plex Mono SmBld",
  serif: "IBM Plex Serif",
  sans: "IBM Plex Sans",
  sans-bold: "IBM Plex Sans SmBld",
  math: "IBM Plex Math",
  cjk-serif: "Source Han Serif SC",
  cjk-sans: "Source Han Sans SC",
)

#set text(
  lang: language,
  font: (fonts.serif, fonts.cjk-serif),
  size: 12pt,
)
#set par(justify: true, leading: 0.8em, spacing: 1.5em)
#show raw: set text(
  font: (fonts.mono, fonts.sans, fonts.cjk-sans),
  size: 1.25em,
  slashed-zero: true,
  ligatures: false,
  features: (ss02: 1, ss06: 1),
)
#show math.equation: set text(font: (fonts.math, fonts.sans, fonts.cjk-sans))
#set strong(delta: 200)
#show strong: it => {
  set text(font: (fonts.sans-bold, fonts.sans, fonts.cjk-sans))
  show raw: set text(font: (fonts.mono-bold, fonts.mono, fonts.sans, fonts.cjk-sans))
  it
}
#show heading: it => {
  set text(font: (fonts.sans-bold, fonts.sans, fonts.cjk-sans), weight: 600)
  show raw: set text(font: (fonts.mono-bold, fonts.mono, fonts.sans, fonts.cjk-sans))
  it
}
#show heading.where(level: 1): it => {
  set text(size: 18pt)
  set heading(bookmarked: true)
  pad(top: 1em, bottom: 1em, align(center, it))
}
#show heading.where(level: 2): it => {
  set text(size: 12pt)
  set heading(bookmarked: true)
  pad(top: 1em, bottom: .5em, [【] + box(it) + [】])
}
#set table(stroke: 0.5pt)

#import "translation/" + language + ".typ" as translation

#set document(
  title: titlecase(hull.display-name.at(language)),
  author: "Hull Build System",
)

#set page(
  margin: (x: 2cm, y: 2cm),
  header: context if show-header.get() {
    grid(
      columns: (1fr, auto),
      // Left side: Contest display name
      text(size: 10pt, titlecase(hull.display-name.at(language))),
      // Right side: Current problem's display name and name
      text(size: 10pt, current-problem-title.get()),
    )
    v(-1em)
    line(length: 100%, stroke: 0.3pt)
  },
  footer: context if show-footer.get() {
    align(
      center,
      text(
        size: 10pt,
        counter(page).display(
          "1 / 1",
          both: true,
        ),
      ),
    )
  },
)

// Helper function to make text flow vertically by inserting zero-width spaces
#let breakable-text(s) = {
  s.clusters().join(sym.zws)
}

/// Recursively and functionally traverses the trace tree to find all nodes tagged with "hull/case".
#let get-case-vis-ranges(tree) = {
  if tree == none {
    return ()
  }

  // Inner helper function. It's a pure function that returns ranges found in its subtree.
  let _traverse(node) = {
    // Find ranges at the current node. Returns a single-element array or an empty one.
    let current_ranges = if "tags" in node and "hull/case" in node.tags {
      let trace = node.trace
      (
        (
          case-id: node.tags.at("hull/case"),
          start: trace.b,
          end: trace.b + trace.l,
        ),
      )
    } else {
      ()
    }

    // Recursively collect ranges from children and concatenate them.
    if "children" in node {
      for child in node.children {
        current_ranges += _traverse(child)
      }
    }

    return current_ranges
  }

  let all_ranges = _traverse(tree)
  // Sort ranges by their start byte for sequential processing.
  return all_ranges.sorted(key: r => r.start)
}

/// Renders a text string with alternating background colors for different test cases,
/// simulating a raw block using a grid for line-by-line alignment in tables.
///
/// - text-str: The raw string to render (e.g., sample input).
/// - trace-tree: The `reader-trace-tree` from the validation JSON.
/// - Returns: A grid-based content block styled to look like a raw block.
#let render-case-vis(sample-id, text-str, trace-tree) = {
  let case-vis-ranges = get-case-vis-ranges(trace-tree)
  let colors = (blue.lighten(90%), green.lighten(90%))

  let lines = text-str.trim("\n", at: end, repeat: false).split("\n")
  let styled-lines = ()
  let current-byte-offset = 0
  let last-case-id = none

  for (line-idx, line-str) in lines.enumerate() {
    let line-byte-len = line-str.len()
    let line-start-byte = current-byte-offset
    let line-end-byte = line-start-byte + line-byte-len

    let intersecting-ranges = case-vis-ranges.filter(r => (
      r.start < line-end-byte and r.end > line-start-byte
    ))

    if intersecting-ranges.len() > 1 {
      panic(
        "in sample "
          + str(sample-id)
          + ", line "
          + str(line-idx)
          + ", intersecting-ranges.len() should be at most 1, but found "
          + str(intersecting-ranges.len()),
      )
    }

    let (case-id, line-color) = if intersecting-ranges.len() == 1 {
      let r = intersecting-ranges.first()
      (r.case-id, colors.at(calc.rem(r.case-id, colors.len())))
    } else {
      // Use `none` for lines without a background color.
      (none, none)
    }


    let tag = if case-id != none and case-id != last-case-id { str(case-id) } else { none }

    // Store the text and its calculated color for later use in the grid.
    styled-lines.push((
      text: breakable-text(line-str),
      color: line-color,
      tag: tag,
    ))

    current-byte-offset += line-byte-len + 1
    last-case-id = case-id
  }

  // Use a block to set the monospaced font for the entire grid.
  pad(
    rect(
      stroke: 0.5pt + rgb("#00f"),
      width: 100%,
      inset: (y: 0.3em),
      block(
        width: 100%,
        {
          set text(font: (fonts.mono, fonts.cjk-sans))
          set par(leading: 0.8em, spacing: 0pt)

          grid(
            columns: (0em, 1fr),
            align: (right, left),
            rows: (auto,) * lines.len(),
            fill: (col, row) => styled-lines.at(row).color,
            inset: ((x: 0pt, y: 0.4em), (x: 0pt, y: 0.4em)),
            ..styled-lines
              .enumerate()
              .map(((line-id, sl)) => (
                grid.cell(
                  move(
                    text(str(line-id + 1), fill: gray, size: 0.8em),
                    dx: -1em,
                    dy: 0.1em,
                  ),
                ),
                grid.cell(sl.text),
              ))
              .flatten()
          )
        },
      ),
    ),
    left: 0.5em,
  )
}

/// Recursively finds all graph objects tagged with "hull/graph" in the trace tree.
#let get-graph-vis-graphs(tree) = {
  if tree == none {
    return ()
  }

  let _traverse(node) = {
    let current_graphs = if "tags" in node and "hull/graph" in node.tags {
      (node.tags.at("hull/graph"),)
    } else {
      ()
    }

    if "children" in node {
      for child in node.children {
        current_graphs += _traverse(child)
      }
    }

    return current_graphs
  }

  let all_graphs = _traverse(tree)
  return all_graphs.sorted(key: g => g.name)
}

#let escape-dot-string(s) = {
  let escaped-parts = ()
  for cluster in str(s).clusters() {
    let escaped-cluster = if cluster == "\\" {
      "\\\""
    } else if cluster == "\\" {
      "\\\\"
    } else {
      cluster
    }
    escaped-parts.push(escaped-cluster)
  }
  return escaped-parts.join("")
}

/// Renders graph visualizations based on `hull/graph` tags in the trace tree.
#let render-graph-vis(sample-idx, trace-tree) = {
  let graphs = get-graph-vis-graphs(trace-tree)

  // Only render the section if there are graphs to display.
  if graphs.len() > 0 {
    heading(level: 2, titlecase(translation.sample-0-graph-visualization(sample-idx)))

    for graph in graphs {
      // Start building the DOT language string.
      let dot-string = "digraph {
        graph [ratio=0.5, rankdir=LR];
        node [shape=circle];
        edge [fontsize=10];
      "

      // Declare all nodes explicitly. This ensures isolated nodes are rendered.
      if "nodes" in graph and graph.nodes != none {
        for node-name in graph.nodes {
          dot-string += "\"" + escape-dot-string(node-name) + "\";"
        }
      }

      // Define all edges.
      if "edges" in graph and graph.edges != none {
        for edge in graph.edges {
          let u = escape-dot-string(edge.u)
          let v = escape-dot-string(edge.v)
          let w = escape-dot-string(edge.w)
          let dir = if "ordered" in edge and edge.ordered { "forward" } else { "none" }
          dot-string += (
            "\""
              + escape-dot-string(u)
              + "\" -> \""
              + escape-dot-string(v)
              + "\" [label=\""
              + escape-dot-string(w)
              + "\", dir="
              + dir
              + "];"
          )
        }
      }

      dot-string += "}"

      // raw(dot-string)
      align(center)[
        #diagraph.render(
          width: 70%,
          engine: "sfdp",
          dot-string,
        )
        #text(size: 0.9em, style: "italic", graph.name)
        #v(1.5em)
      ]
    }
  }
}

#let render-problem(problem, statement) = [
  #show raw.where(block: true): it => {
    set par(leading: 0.8em)
    show raw.line: it => {
      if (it.text == "" and it.number == it.count) {
        return
      }
      box(
        grid(
          columns: (0em, 1fr),
          align: (right, left),
          move(
            text(str(it.number), fill: gray, size: 0.8em),
            dx: -1em,
            dy: 0.1em,
          ),
          it.body,
        ),
      )
    }
    pad(
      rect(it, stroke: 0.5pt + rgb("#00f"), width: 100%, inset: (y: 0.7em)),
      left: 0.5em,
    )
  }

  #align(
    center,
    heading(level: 1, [#titlecase(problem.display-name.at(language)) (#raw(problem.name))]),
  )

  #if statement.description != none [
    #statement.description
  ]

  #if statement.input != none [
    == #titlecase(translation.input-format)

    #statement.input
  ]

  #if statement.output != none [
    == #titlecase(translation.output-format)

    #statement.output
  ]

  #if problem.samples.len() != 0 [
    #for (i, sample) in problem.samples.enumerate(start: 1) {
      heading(level: 2, titlecase(translation.sample-0-input(i)))

      render-case-vis(i, sample.input, sample.input-validation.reader-trace-tree)

      if sample.outputs.len() == 1 {
        heading(level: 2, titlecase(translation.sample-0-output(i)))
        render-case-vis(i, sample.outputs.values().at(0), none)
      } else {
        for (output-name, output) in sample.outputs.pairs() {
          heading(level: 2, titlecase(translation.sample-0-output-1(i, output-name)))
          render-case-vis(i, output, none)
        }
      }

      render-graph-vis(i, sample.input-validation.reader-trace-tree)

      if language in sample.descriptions {
        heading(level: 2, titlecase(translation.sample-0-description(i)))

        eval(sample.descriptions.at(language), mode: "markup")
      }
    }
  ]

  #if problem.traits.len() != 0 [
    == #titlecase(translation.traits)

    #for trait in problem.traits [
      - #strong(trait.at(0)): #eval(trait.at(1).descriptions.at(language), mode: "markup")
    ]
  ]

  #if problem.subtasks.len() >= 2 [
    == #titlecase(translation.subtasks)

    #table(
      columns: (0.5fr, 1fr) + (1fr,) * problem.traits.len(),
      align: (left + bottom, center + bottom, ..problem.traits.keys().map(_ => center + bottom)),
      [*\#*],
      [*#titlecase(translation.score)*],
      ..problem.traits.keys().map(x => text(size: 0.8em, x.clusters().join(sym.zws))),
      ..problem
        .subtasks
        .enumerate(start: 1)
        .map(((id, st)) => {
          (
            ([#id], $#str(st.full-score * 100)$)
              + problem
                .traits
                .keys()
                .map(trait => {
                  if not st.traits.keys().contains(trait) {
                    table.cell(fill: yellow.lighten(60%))[?]
                  } else if st.traits.at(trait) {
                    table.cell(fill: green.lighten(60%))[#sym.checkmark]
                  } else {
                    table.cell(fill: red.lighten(60%))[$times$]
                  }
                })
          )
        })
        .flatten(),
    )
  ]

  #if statement.notes != none [
    == #titlecase(translation.notes)

    #statement.notes
  ]
]

#let problem-table(problems) = {
  set par(justify: false, leading: 0.4em, spacing: 1.2em)

  let first-column-width = if hull.problems.len() <= 3 { 25% } else { 1.2fr }
  let tick-or-time-limit = if render.ticks-per-ms == none {
    (
      [*#titlecase(translation.tick-limit)*],
      ..problems.map(p => translation.ticks(p.tick-limit)),
    )
  } else {
    (
      [*#titlecase(translation.time-limit)*],
      ..problems.map(p => translation.milliseconds(p.tick-limit / render.ticks-per-ms)),
    )
  }

  table(
    columns: (first-column-width,) + (1fr,) * problems.len(),
    [*#titlecase(translation.problem-name)*], ..problems.map(p => titlecase(
      p.display-name.at(language),
    )),
    [*#titlecase(translation.directory)*], ..problems.map(p => raw(breakable-text(p.name))),
    ..tick-or-time-limit,
    [*#titlecase(translation.memory-limit)*], ..problems.map(p => translation.bytes(
      p.memory-limit,
    )),
    [*#titlecase(translation.full-score)*], ..problems.map(p => [$#(p.full-score * 100)$]),
  )

  [*#titlecase(translation.source-program-file-name)*]

  table(
    columns: (first-column-width,) + (1fr,) * problems.len(),
    ..render
      .languages
      .map(lang => (
        ([*#titlecase(translation.for-0-language(lang.display-name))*],)
          + problems.map(p => raw(breakable-text(p.name + lang.file-name-suffix)))
      ))
      .flatten(),
  )

  [*#titlecase(translation.compile-arguments)*]

  table(
    columns: (25%, 1fr),
    ..render
      .languages
      .map(lang => (
        (
          [*#titlecase(translation.for-0-language(lang.display-name))*],
          [#raw(lang.compile-arguments)],
        )
      ))
      .flatten(),
  )
}

#align(center, heading(level: 1, text(size: 1.2em, titlecase(hull.display-name.at(language)))))

#problem-table(hull.problems)

*#titlecase(translation.notes)*

#translation.contest-notes-body

#for (problem-id, problem) in hull.problems.enumerate(start: 1) {
  current-problem-title.update(
    titlecase(problem.display-name.at(language)) + " (" + raw(problem.name) + ")",
  )

  if problem-id == 1 {
    show-header.update(true)
  }
  pagebreak()
  if problem-id == 1 {
    show-footer.update(true)
  }

  import "problem/" + problem.name + "/" + language + ".typ" as statement
  render-problem(problem, statement)
}
