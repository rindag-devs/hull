#import "@preview/tablex:0.0.9": tablex, hlinex, cellx
#import "@preview/titleize:0.1.1": titlecase

#let get-input-or-default(name, default) = {
  if sys.inputs.keys().contains(name) {
    sys.inputs.at(name)
  } else {
    default
  }
}

#let render-problem(problem, statement, translation, language) = [
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
    == #titlecase(translation.samples)

    #for sample in problem.samples {
      table(
        columns: (1fr,) * (sample.outputs.len() + 1),
        align(center, raw("input")),
        ..sample.outputs.keys().map(x => align(center, raw(x))),
        raw(block: true, sample.input),
        ..sample.outputs.values().map(x => raw(block: true, x))
      )
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

    #tablex(
      columns: (0.5fr, 1fr) + (1fr,) * problem.traits.len(),
      align: (left + bottom, center + bottom, ..problem.traits.keys().map(_ => center + bottom)),
      auto-lines: false,
      header-rows: 1,
      [*\#*],
      [*#titlecase(translation.score)*],
      ..problem.traits.keys().map(x => text(size: 0.8em, x.clusters().join(sym.zws))),
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
#let hull = json(hull-generated-json-path)

#let language = get-input-or-default("language", "en")

#show "。": "．"

#set text(
  lang: language,
  font: (
    "Libertinus Serif",
    "Source Han Serif",
  ),
)

#import "problem/" + language + ".typ" as statement
#import "translation/" + language + ".typ" as translation

#render-problem(hull, statement, translation, language)
