// Base template with shared content show rules.

#import "/templates/tola.typ" as tola

// ============================================================================
// Base Layout
// ============================================================================

#let base(body) = {
  // --------------------------------------------------------------------------
  // Inherit Tola base (figure/table/math handling)
  // --------------------------------------------------------------------------

  show: tola.tola-base.with(
    figure-class: "figure",
    // Keep inline math in normal inline formatting context so SVG
    // `vertical-align` baseline offsets are effective.
    math-inline-class: "math-inline",
    math-block-class: "math-block",
  )

  // --------------------------------------------------------------------------
  // Show Rules: Lists
  // --------------------------------------------------------------------------

  show list: it => html.ul[
    #for item in it.children { html.li[#item.body] }
  ]
  show enum: it => html.ol[
    #for item in it.children { html.li[#item.body] }
  ]

  // --------------------------------------------------------------------------
  // Show Rules: Code
  // --------------------------------------------------------------------------

  show raw.where(block: false): it => html.code[#it.text]

  show raw.where(block: true): it => {
    let lang = if it.lang == none { "text" } else { it.lang }
    html.pre[#html.code(class: "language-" + lang)[#it.text]]
  }

  // --------------------------------------------------------------------------
  // Show Rules: Text Elements
  // --------------------------------------------------------------------------

  show quote: it => html.blockquote[#it.body]
  show link: it => html.a(
    href: repr(it.dest).replace("\"", ""),
  )[#it.body]

  // --------------------------------------------------------------------------
  // Render
  // --------------------------------------------------------------------------

  body
}
