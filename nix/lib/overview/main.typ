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

#import "@preview/oxifmt:1.0.0": strfmt
#import "@preview/tablex:0.0.9": tablex, hlinex, cellx, colspanx

// Helper to get input from command line or use a default for local testing
#let get-input-or-default(name, default) = {
  if sys.inputs.keys().contains(name) {
    sys.inputs.at(name)
  } else {
    default
  }
}

// Load the problem data from the JSON file passed by the build system
#let hull-generated-json-path = get-input-or-default(
  "hull-generated-json-path",
  "hull-generated.example.json", // A local example file for development
)
#let problem = json(hull-generated-json-path)

// Helper functions for formatting values (provided in the prompt)
#let format-size(num) = {
  let rounded = calc.round(num, digits: 3)
  let s = repr(rounded)
  if s.contains(".") {
    s = s.trim("0").trim(".")
  }
  s
}

#let ticks(n) = {
  if n < 100000 {
    [$#n$ ticks]
  } else {
    let exponent = calc.floor(calc.log(n, base: 10))
    let mantissa = n / calc.pow(10, exponent)
    let rounded_mantissa = calc.round(mantissa, digits: 3)
    let mantissa_str = str(rounded_mantissa)
    [$#mantissa_str times 10^#exponent$ ticks]
  }
}

#let bytes(n) = {
  let KiB = 1024.0
  let MiB = KiB * 1024
  let GiB = MiB * 1024
  let TiB = GiB * 1024

  if n <= KiB {
    $#n$ + " bytes"
  } else if n <= MiB {
    $#format-size(n / KiB)$ + " KiB"
  } else if n <= GiB {
    $#format-size(n / MiB)$ + " MiB"
  } else if n <= TiB {
    $#format-size(n / GiB)$ + " GiB"
  } else {
    $#format-size(n / TiB)$ + " TiB"
  }
}

// Custom helper function to display status as a colored badge
#let status-badge(status) = {
  let (name, color) = (
    ("accepted", ("AC", green)),
    ("wrong_answer", ("WA", red)),
    ("partially_correct", ("PC", aqua)),
    ("time_limit_exceeded", ("TLE", yellow)),
    ("memory_limit_exceeded", ("MLE", yellow)),
    ("runtime_error", ("RE", purple)),
    ("internal_error", ("IE", gray)),
  )
    .find(x => x.at(0) == status)
    .at(1)
  box(
    inset: (x: 4pt, y: 1pt),
    fill: color.lighten(80%),
    text(fill: color.darken(60%), weight: "bold", name),
  )
}

// Helper function to make text flow vertically by inserting zero-width spaces
#let vertical-text(s) = {
  s.clusters().join(sym.zws)
}

// Document Configuration
#set document(
  title: problem.name + " - Hull Problem Overview",
  author: "hull build system",
)
#set page(margin: (x: 2cm, y: 2.5cm))

// Title
#align(center)[
  #text(size: 2em, weight: "bold", "Hull Problem Overview")
  #v(1em)
  #text(size: 1.5em, raw(problem.name, lang: "txt"))
]

#v(2em)

= General Information

#grid(
  columns: (150pt, 1fr),
  rows: auto,
  gutter: 1em,
  [Full Score:], $#strfmt("{:.3}", problem.at("full-score"))$,
  [Default Tick Limit:], ticks(problem.at("tick-limit")),
  [Default Memory Limit:], bytes(problem.at("memory-limit")),
  [Build Date:], [#datetime.today().display("[year]-[month]-[day]")],
)

#pagebreak()
= Traits

#tablex(
  columns: (auto, 1fr),
  align: (left, left),
  auto-lines: false,
  header-rows: 1,
  // Header
  [*Trait Name*],
  [*Description (en)*],
  hlinex(),
  // Body
  ..problem
    .traits
    .pairs()
    .map(((name, trait)) => (
      raw(name, lang: "txt"),
      trait.description.at("en", default: text(gray)[(none)]),
    ))
    .flatten(),
)

#pagebreak()
= Test Cases

// Table 1: General Information
#tablex(
  columns: (auto, auto, 1fr, auto),
  align: (left, left, left, center),
  auto-lines: false,
  header-rows: 1,
  // Header
  [*Name*],
  [*Generator*],
  [*Arguments*],
  [*Groups*],
  hlinex(),
  // Body
  ..problem
    .at("test-cases")
    .pairs()
    .map(((name, tc)) => (
      raw(name, lang: "txt"),
      if tc.generator != none { raw(tc.generator, lang: "txt") } else { text(gray)[(manual)] },
      if tc.arguments != none { raw(tc.arguments.join(" "), lang: "txt") } else {
        text(gray)[(none)]
      },
      if tc.groups.len() > 0 { tc.groups.join(", ") } else { text(gray)[(none)] },
    ))
    .flatten(),
)

// Table 2: Trait Matrix
== Test Case Trait Matrix

#let all_trait_names = problem.traits.keys().sorted()
#let test_case_pairs = problem.at("test-cases").pairs().sorted(key: p => p.at(0))

#tablex(
  columns: (auto, ..all_trait_names.map(_ => 1fr)),
  align: (left + bottom, ..all_trait_names.map(_ => center + bottom)),
  auto-lines: false,
  header-rows: 1,
  // Header
  [*Test Case*],
  ..all_trait_names.map(name => text(size: 0.8em, vertical-text(name))),
  hlinex(),
  // Body
  ..test_case_pairs
    .map(((name, tc)) => {
      (
        raw(name, lang: "txt"),
        ..all_trait_names.map(trait_name => {
          let actual_traits = tc.at("actual-traits")
          let (symbol, color) = if actual_traits.keys().contains(trait_name) {
            if actual_traits.at(trait_name) {
              (sym.checkmark, green.lighten(60%))
            } else {
              ($times$, red.lighten(60%))
            }
          } else {
            ("?", yellow.lighten(60%))
          }
          cellx(fill: color, align(center, symbol))
        }),
      )
    })
    .flatten(),
)


#pagebreak()
= Subtasks

#tablex(
  columns: (auto, auto, 1fr, 1.5fr),
  align: (center, center, left, left),
  auto-lines: false,
  header-rows: 1,
  // Header
  [*Subtask*],
  [*Score*],
  [*Required Traits*],
  [*Test Cases*],
  hlinex(),
  // Body
  ..problem
    .subtasks
    .enumerate()
    .map(((i, st)) => (
      i + 1,
      strfmt("{:.3}", st.at("full-score")),
      {
        let traits = st
          .traits
          .pairs()
          .filter(p => p.at(1) == true)
          .map(p => raw(p.at(0), lang: "txt"))
        if traits.len() > 0 {
          traits.join(", ")
        } else {
          text(gray)[(none)]
        }
      },
      st.at("test-cases").map(name => raw(name, lang: "txt")).join(", "),
    ))
    .flatten(),
)

#pagebreak()
= Solutions Analysis

#let test-case-names = problem.at("test-cases").keys().sorted()
#let solution-names = problem.solutions.keys().sorted()

#tablex(
  // Columns: One for test case names, then one for each solution.
  columns: (auto, ..solution-names.map(_ => 1fr)),
  // Align: Test case names left, results centered.
  align: (left + bottom, ..solution-names.map(_ => center + bottom)),
  auto-lines: false,
  header-rows: 1,

  // --- Header Row ---
  // First cell is the corner label.
  [*Test Case*],
  // The rest of the header cells are the solution names.
  ..solution-names.map(name => {
    let sol = problem.solutions.at(name)
    let is_main = sol.at("main-correct-solution")
    // Use a smaller font and add a star for the main solution.
    text(
      size: 0.8em,
      weight: "bold",
      if is_main { [*#emoji.star #vertical-text(name)*] } else { [#vertical-text(name)] },
    )
  }),

  hlinex(),

  // --- Body Rows (one for each test case) ---
  ..test-case-names
    .map(tc_name => {
      (
        // This is a row tuple
        // First cell: The test case name.
        raw(tc_name, lang: "txt"),
        // Subsequent cells: The status badge for each solution on this test case.
        ..solution-names.map(sol_name => {
          let result = problem.solutions.at(sol_name).at("test-case-results").at(tc_name)
          status-badge(result.status)
        }),
      )
    })
    .flatten(),

  hlinex(),

  // Subtasks
  [*Subtask*],
  colspanx(solution-names.len(), align: left)[*Score*],

  hlinex(),

  ..problem
    .subtasks
    .enumerate()
    .map(((i, st)) => (
      i + 1,
      ..solution-names.map(sol => {
        let score = problem.solutions.at(sol).subtask-results.at(i).scaled-score
        strfmt("{:.3}", score)
      }),
    ))
    .flatten(),

  hlinex(),

  // Footer Row (for total scores)
  // First cell: The label for the score row.
  [*Total*],
  // Subsequent cells: The total score for each solution.
  ..solution-names
    .map(sol_name => {
      let sol = problem.solutions.at(sol_name)
      let total_score = sol.at("subtask-results").map(st => st.at("scaled-score")).sum(default: 0)
      text(weight: "bold", strfmt("{:.3}", total_score))
    })
    .flatten(),
)

#if problem.samples.len() > 0 {
  pagebreak()
  [= Sample Cases]
  for (i, sample) in problem.samples.enumerate() {
    [== Sample #str(i + 1)]

    table(
      columns: (1fr,) * sample.len(), ..sample.keys().map(x => align(center, raw(x))), ..sample
        .values()
        .map(x => raw(block: true, x))
    )
  }
}
