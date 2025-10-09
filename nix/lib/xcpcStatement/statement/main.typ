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

#import "@preview/tablex:0.0.9": tablex, hlinex, cellx
#import "@preview/titleize:0.1.1": titlecase
#import "@preview/diagraph:0.3.6"

#let get-input-or-default(name, default) = {
  if sys.inputs.keys().contains(name) {
    sys.inputs.at(name)
  } else {
    default
  }
}

#let language = get-input-or-default("language", "en")

#show "。": "．"

#set text(
  lang: language,
  font: (
    "Libertinus Serif",
    "Source Han Serif",
  ),
)

#set par(justify: true, leading: 0.8em, spacing: 1.5em)

#import "translation/" + language + ".typ" as translation

// Helper function to make text flow vertically by inserting zero-width spaces
#let breakable-text(s) = {
  s.clusters().join(sym.zws)
}

/// Recursively and functionally traverses the trace tree to find all nodes tagged with "case-vis_case".
///
/// - tree: The trace tree node to start from.
/// - Returns: An array of dictionaries, each with `case-id`, `start`, and `end` byte offsets.
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
  block(
    width: 100%,
    {
      set text(font: "Dejavu Sans Mono", size: 0.8em)
      set par(leading: 0.6em, spacing: 0pt)

      grid(
        columns: (0em, 1fr),
        rows: (auto,) * lines.len(),
        fill: (col, row) => styled-lines.at(row).color,
        inset: ((x: 0pt, y: 0.3em), (x: 4pt, y: 0.3em)),
        align: (right + horizon, left + horizon),
        ..styled-lines
          .map(sl => (
            grid.cell(
              move(text(size: 0.8em, fill: gray, if sl.tag != none { str(sl.tag) }), dx: -0.4em),
            ),
            grid.cell(sl.text),
          ))
          .flatten()
      )
    },
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
#let render-graph-vis(trace-tree) = {
  let graphs = get-graph-vis-graphs(trace-tree)

  // Only render the section if there are graphs to display.
  if graphs.len() > 0 {
    [=== #titlecase(translation.graph-visualization)]

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
  = #titlecase(problem.display-name.at(language))

  #grid(
    columns: (auto, auto),
    inset: 0% + 3pt,
    [#titlecase(translation.tick-limit):], translation.ticks(problem.tick-limit),
    [#titlecase(translation.memory-limit):], translation.bytes(problem.memory-limit),
  )

  #line(length: 100%)

  #if statement.description != none [
    #statement.description
  ]

  #if statement.input != none [
    == #titlecase(translation.input)

    #statement.input
  ]

  #if statement.output != none [
    == #titlecase(translation.output)

    #statement.output
  ]

  #if problem.samples.len() != 0 [
    #for (idx, sample) in problem.samples.enumerate() {
      if sample.len() > 1 [
        == #titlecase(translation.sample-0(idx + 1))
      ] else [
        == #titlecase(translation.sample)
      ]

      table(
        columns: (1fr,) * (sample.outputs.len() + 1),
        align(center, raw("input")),
        ..sample.outputs.keys().map(x => align(center, raw(breakable-text(x)))),
        table.cell(
          inset: 1pt,
          render-case-vis(idx, sample.input, sample.input-validation.reader-trace-tree),
        ),
        ..sample
          .outputs
          .values()
          .map(x => table.cell(
            inset: 1pt,
            render-case-vis(idx, x, none),
          ))
      )

      render-graph-vis(sample.input-validation.reader-trace-tree)

      if language in sample.descriptions {
        [=== #titlecase(translation.description)]

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

    #tablex(
      columns: (0.5fr, 1fr) + (1fr,) * problem.traits.len(),
      align: (left + bottom, center + bottom, ..problem.traits.keys().map(_ => center + bottom)),
      auto-lines: false,
      header-rows: 1,
      [*\#*],
      [*#titlecase(translation.score)*],
      ..problem.traits.keys().map(x => text(size: 0.8em, breakable-text(x))),
      hlinex(),
      ..problem
        .subtasks
        .enumerate(start: 1)
        .map(((id, st)) => {
          (
            ([#id], $#str(st.full-score)$)
              + problem
                .traits
                .keys()
                .map(trait => {
                  if not st.traits.keys().contains(trait) {
                    cellx(fill: yellow.lighten(60%))[?]
                  } else if st.traits.at(trait) {
                    cellx(fill: green.lighten(60%))[#sym.checkmark]
                  } else {
                    cellx(fill: red.lighten(60%))[$times$]
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

#let hull-generated-json-path = get-input-or-default(
  "hull-generated-json-path",
  "hull-generated.example.json",
)
#let problem = json(hull-generated-json-path)

#import "problem/" + language + ".typ" as statement

#set document(
  title: problem.name + " - Problem Statement",
  author: "Hull Build System",
)
#set page(margin: (x: 2cm, y: 2.5cm))

#render-problem(problem, statement)
