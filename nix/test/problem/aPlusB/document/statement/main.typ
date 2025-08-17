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

#import "problem/" + language + ".typ" as problem
#import "translation/" + language + ".typ" as translation

= #titlecase(hull.name.at(language))

#grid(
  columns: (auto, auto),
  inset: 0% + 3pt,
  [#titlecase(translation.tick_limit):], translation.ticks(hull.tick-limit),
  [#titlecase(translation.memory_limit):], translation.bytes(hull.memory-limit),
)

#line(length: 100%)

#problem.description

== #titlecase(translation.input)

#problem.input

== #titlecase(translation.output)

#problem.output

== #titlecase(translation.samples)

#for sample in hull.samples {
  table(
    columns: (1fr,) * sample.len(), ..sample.keys().map(x => align(center, raw(x))), ..sample
      .values()
      .map(x => raw(block: true, x))
  )
}


== #titlecase(translation.traits)

#for trait in hull.traits [
  - #strong(trait.at(0)): #eval(trait.at(1).at(language), mode: "markup")
]

== #titlecase(translation.subtasks)

#[
  #table(columns: (0.5fr, 1fr) + (1fr,) * hull.traits.len(), [\#], [Score], ..hull
      .traits
      .keys()
      .map(x => x.clusters().join(sym.zws)), ..hull
      .subtasks
      .enumerate(start: 1)
      .map(((id, st)) => {
        (
          ([#id], $#st.full-score$)
            + hull
              .traits
              .keys()
              .map(trait => {
                if not st.traits.keys().contains(trait) {
                  [?]
                } else if st.traits.at(trait) {
                  [$sqrt("")$]
                } else {
                  [$times$]
                }
              })
        )
      })
      .flatten())
]
