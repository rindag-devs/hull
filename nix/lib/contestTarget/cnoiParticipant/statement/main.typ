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

      raw(block: true, sample.input)

      if sample.outputs.len() == 1 {
        heading(level: 2, titlecase(translation.sample-0-output(i)))
        raw(block: true, sample.outputs.values().at(0))
      } else {
        for (output-name, output) in sample.outputs.pairs() {
          heading(level: 2, titlecase(translation.sample-0-output-1(i, output-name)))
          raw(block: true, output)
        }
      }
    }
  ]


  #if problem.traits.len() != 0 [
    == #titlecase(translation.traits)

    #for trait in problem.traits [
      - #strong(trait.at(0)): #eval(trait.at(1).description.at(language), mode: "markup")
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
