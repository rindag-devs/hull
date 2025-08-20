#import "@preview/oxifmt:1.0.0": strfmt
#import "@preview/tablex:0.0.9": tablex, hlinex, cellx
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

#set document(
  title: hull.name + " - Hull Problem Overview",
  author: "hull build system",
)
#set page(margin: (x: 2cm, y: 2.5cm))

= #titlecase(hull.display-name.at(language))

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
  - #strong(trait.at(0)): #eval(trait.at(1).description.at(language), mode: "markup")
]

== #titlecase(translation.subtasks)

#tablex(
  columns: (0.5fr, 1fr) + (1fr,) * hull.traits.len(),
  align: (left + bottom, center + bottom, ..hull.traits.keys().map(_ => center + bottom)),
  auto-lines: false,
  header-rows: 1,
  [*\#*],
  [*#titlecase(translation.score)*],
  ..hull.traits.keys().map(x => text(size: 0.8em, x.clusters().join(sym.zws))),
  hlinex(),
  ..hull
    .subtasks
    .enumerate(start: 1)
    .map(((id, st)) => {
      (
        ([#id], $#strfmt("{:.3}", st.full-score)$)
          + hull
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
