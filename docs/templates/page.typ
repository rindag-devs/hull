#import "/templates/tola.typ": wrap-page
#import "/templates/base.typ": base
#import "/templates/navigation.typ": introduction, nav-sections
#import "@tola/site:0.0.0": info
#import "@tola/current:0.0.0": current-permalink

#let normalize-permalink(value) = {
  let text = str(value)
  if text.ends-with("/") and text != "/" {
    text.slice(0, text.len() - 1)
  } else {
    text
  }
}

#let permalink-active(href) = normalize-permalink(current-permalink) == normalize-permalink(href)

#let chapter-link(item, number) = {
  let active = permalink-active(item.href)
  html.li(class: "chapter-item")[
    #html.a(
      class: if active { "chapter-link active" } else { "chapter-link" },
      href: item.href,
    )[
      #html.strong[#number]
      #item.title
    ]
  ]
}

#let svg-icon(path, class: none) = html.span(class: if class == none {
  "fa-svg"
} else {
  "fa-svg " + class
})[
  #html.elem(
    "svg",
    attrs: (
      viewBox: "0 0 16 16",
      width: "1em",
      height: "1em",
      "aria-hidden": "true",
    ),
  )[
    #html.elem("path", attrs: (fill: "currentColor", d: path))
  ]
]

#let bars-icon = html.span(class: "fa-svg")[
  #html.elem(
    "svg",
    attrs: (
      viewBox: "0 0 448 512",
      width: "1em",
      height: "1em",
      "aria-hidden": "true",
    ),
  )[
    #html.elem("path", attrs: (
      fill: "currentColor",
      d: "M0 96C0 78.3 14.3 64 32 64H416c17.7 0 32 14.3 32 32s-14.3 32-32 32H32C14.3 128 0 113.7 0 96zM0 256c0-17.7 14.3-32 32-32H416c17.7 0 32 14.3 32 32s-14.3 32-32 32H32c-17.7 0-32-14.3-32-32zM448 416c0 17.7-14.3 32-32 32H32c-17.7 0-32-14.3-32-32s14.3-32 32-32H416c17.7 0 32 14.3 32 32z",
    ))
  ]
]

#let paintbrush-icon = html.span(class: "fa-svg")[
  #html.elem(
    "svg",
    attrs: (
      viewBox: "0 0 576 512",
      width: "1em",
      height: "1em",
      "aria-hidden": "true",
    ),
  )[
    #html.elem("path", attrs: (
      fill: "currentColor",
      d: "M339.3 367.1c27.3-3.9 51.9-19.4 67.2-42.9L568.2 74.1c12.6-19.5 9.4-45.3-7.6-61.1S518.4-4.4 500.6 10.4L271.2 201c-21.2 17.6-33.1 43.9-32.6 71.4.1 7.7.9 15.3 2.3 22.8L339.3 367.1zM192 384c0-35.3 28.7-64 64-64h35.1L224.4 253.3c-19.7 7.8-37.2 20.7-50.5 37.7L144 329.2V320c0-17.7-14.3-32-32-32s-32 14.3-32 32v64H16c-8.8 0-16 7.2-16 16c0 61.9 50.1 112 112 112h176c26.5 0 48-21.5 48-48c0-44.2-35.8-80-80-80H192z",
    ))
  ]
]

#let magnifying-glass-icon = html.span(class: "fa-svg")[
  #html.elem(
    "svg",
    attrs: (
      viewBox: "0 0 512 512",
      width: "1em",
      height: "1em",
      "aria-hidden": "true",
    ),
  )[
    #html.elem("path", attrs: (
      fill: "currentColor",
      d: "M416 208c0 45.9-14.9 88.3-40 122.7L502.6 457.4c12.5 12.5 12.5 32.8 0 45.3s-32.8 12.5-45.3 0L330.7 376C296.3 401.1 253.9 416 208 416C93.1 416 0 322.9 0 208S93.1 0 208 0S416 93.1 416 208zM208 352a144 144 0 1 0 0-288 144 144 0 1 0 0 288z",
    ))
  ]
]

#let print-icon = html.span(class: "fa-svg print-button")[
  #html.elem(
    "svg",
    attrs: (
      viewBox: "0 0 512 512",
      width: "1em",
      height: "1em",
      "aria-hidden": "true",
    ),
  )[
    #html.elem("path", attrs: (
      fill: "currentColor",
      d: "M128 0C92.7 0 64 28.7 64 64v96h64V64h226.7L384 93.3V160h64V93.3c0-17-6.7-33.3-18.7-45.3L400 18.7C388 6.7 371.7 0 354.7 0H128zM384 352v96H128v-96h256zm64 32h32c17.7 0 32-14.3 32-32V224c0-35.3-28.7-64-64-64H64c-35.3 0-64 28.7-64 64v128c0 17.7 14.3 32 32 32h32v64c0 35.3 28.7 64 64 64h256c35.3 0 64-28.7 64-64v-64zM432 248a24 24 0 1 1 0 48 24 24 0 1 1 0-48z",
    ))
  ]
]

#let github-icon = html.span(class: "fa-svg")[
  #html.elem(
    "svg",
    attrs: (
      viewBox: "0 0 16 16",
      width: "1em",
      height: "1em",
      "aria-hidden": "true",
    ),
  )[
    #html.elem(
      "path",
      attrs: (
        fill: "currentColor",
        d: "M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82A7.62 7.62 0 0 1 8 3.87c.68 0 1.36.09 2 .26 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z",
      ),
    )
  ]
]

#let sidebar() = html.nav(
  id: "mdbook-sidebar",
  class: "sidebar",
  aria-label: "Table of contents",
)[
  #html.elem("mdbook-sidebar-scrollbox", attrs: (class: "sidebar-scrollbox"))[
    #html.ol(class: "chapter")[
      #html.li(class: "chapter-item")[
        #html.a(
          class: if permalink-active(introduction.href) { "chapter-link active" } else {
            "chapter-link"
          },
          href: introduction.href,
        )[#introduction.title]
      ]
      #let number = 1
      #for section in nav-sections {
        html.li(class: "spacer")[]
        html.li(class: "part-title")[#section.title]
        for item in section.pages {
          chapter-link(item, str(number) + ".")
          number += 1
        }
      }
    ]
  ]
  #html.div(id: "mdbook-sidebar-resize-handle", class: "sidebar-resize-handle")[
    #html.div(class: "sidebar-resize-indicator")[]
  ]
]

#let page = wrap-page(
  base: base,
  head: m => [
    #html.elem("meta", attrs: (charset: "UTF-8"))
    #html.elem("meta", attrs: (
      name: "viewport",
      content: "width=device-width, initial-scale=1",
    ))
    #html.elem("meta", attrs: (name: "theme-color", content: "#ffffff"))
    #html.elem("link", attrs: (rel: "stylesheet", href: "/css/variables.css"))
    #html.elem("link", attrs: (rel: "stylesheet", href: "/css/general.css"))
    #html.elem("link", attrs: (rel: "stylesheet", href: "/css/chrome.css"))
    #html.elem("link", attrs: (
      rel: "stylesheet",
      href: "/pagefind/pagefind-ui.css",
    ))
    #html.elem("link", attrs: (
      rel: "preconnect",
      href: "https://fonts.googleapis.com",
    ))
    #html.elem("link", attrs: (
      rel: "preconnect",
      href: "https://fonts.gstatic.com",
      crossorigin: "",
    ))
    #html.elem("link", attrs: (
      rel: "stylesheet",
      href: "https://fonts.googleapis.com/css2?family=Open+Sans:wght@300;400;600;700;800&family=Source+Code+Pro:wght@500&display=swap",
    ))
    #if m.title != none {
      html.title(m.title + " | " + info.title)
    } else {
      html.title(info.title)
    }
  ],
  view: (body, m) => {
    show heading.where(level: 1): it => html.h1(class: "header")[#it.body]
    show heading.where(level: 2): it => html.h2(class: "header")[#it.body]
    show heading.where(level: 3): it => html.h3(class: "header")[#it.body]

    html.div(id: "mdbook-help-container")[
      #html.div(id: "mdbook-help-popup")[
        #html.h2(class: "mdbook-help-title")[Keyboard shortcuts]
        #html.div[
          #html.p[Press #html.kbd[?] to show this help]
          #html.p[Press #html.kbd[Esc] to hide this help]
        ]
      ]
    ]
    html.div(id: "mdbook-body-container")[
      #html.script(
        "try{let theme=localStorage.getItem('mdbook-theme');let sidebar=localStorage.getItem('mdbook-sidebar');if(theme&&theme.startsWith('\"')&&theme.endsWith('\"')){localStorage.setItem('mdbook-theme',theme.slice(1,theme.length-1));}if(sidebar&&sidebar.startsWith('\"')&&sidebar.endsWith('\"')){localStorage.setItem('mdbook-sidebar',sidebar.slice(1,sidebar.length-1));}}catch(e){}",
      )
      #html.script(
        "const path_to_root='/';const default_light_theme='light';const default_dark_theme='coal';const default_theme=window.matchMedia('(prefers-color-scheme: dark)').matches?default_dark_theme:default_light_theme;let theme;try{theme=localStorage.getItem('mdbook-theme');}catch(e){}if(theme===null||theme===undefined){theme=default_theme;}const html=document.documentElement;html.classList.add(theme);html.classList.add('sidebar-visible');html.classList.add('js');",
      )
      #html.input(
        type: "checkbox",
        id: "mdbook-sidebar-toggle-anchor",
        class: "hidden",
      )
      #html.script(
        "let sidebar=null;const sidebar_toggle=document.getElementById('mdbook-sidebar-toggle-anchor');if(document.body.clientWidth>=1080){try{sidebar=localStorage.getItem('mdbook-sidebar');}catch(e){}sidebar=sidebar||'visible';}else{sidebar='hidden';sidebar_toggle.checked=false;}if(sidebar==='visible'){sidebar_toggle.checked=true;html.classList.add('sidebar-visible');}else{html.classList.remove('sidebar-visible');}",
      )
      #sidebar()
      #html.div(id: "mdbook-page-wrapper", class: "page-wrapper")[
        #html.div(class: "page")[
          #html.div(id: "mdbook-menu-bar-hover-placeholder")[]
          #html.div(id: "mdbook-menu-bar", class: "menu-bar sticky")[
            #html.div(class: "left-buttons")[
              #html.elem(
                "label",
                attrs: (
                  id: "mdbook-sidebar-toggle",
                  class: "icon-button",
                  "for": "mdbook-sidebar-toggle-anchor",
                  title: "Toggle Table of Contents",
                  "aria-label": "Toggle Table of Contents",
                  "aria-controls": "mdbook-sidebar",
                  "aria-expanded": "true",
                ),
              )[#bars-icon]
              #html.elem(
                "button",
                attrs: (
                  id: "mdbook-theme-toggle",
                  class: "icon-button",
                  type: "button",
                  title: "Change theme",
                  "aria-label": "Change theme",
                  "aria-haspopup": "true",
                  "aria-expanded": "false",
                  "aria-controls": "mdbook-theme-list",
                ),
              )[#paintbrush-icon]
              #html.ul(
                id: "mdbook-theme-list",
                class: "theme-popup",
                aria-label: "Themes",
                role: "menu",
              )[
                #html.elem("li", attrs: (role: "none"))[#html.elem(
                  "button",
                  attrs: (
                    role: "menuitem",
                    class: "theme",
                    id: "mdbook-theme-default_theme",
                  ),
                )[Auto]]
                #html.elem("li", attrs: (role: "none"))[#html.elem(
                  "button",
                  attrs: (
                    role: "menuitem",
                    class: "theme",
                    id: "mdbook-theme-light",
                  ),
                )[Light]]
                #html.elem("li", attrs: (role: "none"))[#html.elem(
                  "button",
                  attrs: (
                    role: "menuitem",
                    class: "theme",
                    id: "mdbook-theme-rust",
                  ),
                )[Rust]]
                #html.elem("li", attrs: (role: "none"))[#html.elem(
                  "button",
                  attrs: (
                    role: "menuitem",
                    class: "theme",
                    id: "mdbook-theme-coal",
                  ),
                )[Coal]]
                #html.elem("li", attrs: (role: "none"))[#html.elem(
                  "button",
                  attrs: (
                    role: "menuitem",
                    class: "theme",
                    id: "mdbook-theme-navy",
                  ),
                )[Navy]]
                #html.elem("li", attrs: (role: "none"))[#html.elem(
                  "button",
                  attrs: (
                    role: "menuitem",
                    class: "theme",
                    id: "mdbook-theme-ayu",
                  ),
                )[Ayu]]
              ]
              #html.elem(
                "button",
                attrs: (
                  id: "pagefind-search-toggle",
                  class: "icon-button",
                  type: "button",
                  title: "Search (`/`)",
                  "aria-label": "Toggle search",
                  "aria-expanded": "false",
                  "aria-keyshortcuts": "/ s",
                  "aria-controls": "pagefind-search-panel",
                ),
              )[#magnifying-glass-icon]
            ]
            #html.h1(class: "menu-title")[#info.title]
            #html.div(class: "right-buttons")[
              #html.elem(
                "a",
                attrs: (
                  href: "#",
                  id: "mdbook-print-button",
                  title: "Print this book",
                  "aria-label": "Print this book",
                  onclick: "window.print();return false;",
                ),
              )[#print-icon]
              #html.a(
                href: "https://github.com/rindag-devs/hull",
                title: "Git repository",
                aria-label: "Git repository",
              )[#github-icon]
            ]
          ]

          #html.div(
            id: "pagefind-search-panel",
            class: "pagefind-search-panel hidden",
          )[
            #html.div(id: "pagefind-search")[]
          ]

          #html.div(class: "content")[
            #html.elem("main", attrs: ("data-pagefind-body": ""))[
              #body
            ]
            #html.nav(class: "nav-wrapper", aria-label: "Page navigation")[
              #html.div(style: "clear: both")[]
            ]
          ]
        ]
        #html.nav(class: "nav-wide-wrapper", aria-label: "Page navigation")[]
      ]
      #html.script("window.playground_copyable=true;")
      #html.script(src: "/pagefind/pagefind-ui.js")
      #html.script(src: "/scripts/pagefind.js")
      #html.elem("script", attrs: (type: "module", src: "/scripts/shiki.js"))
      #html.script(src: "/scripts/sidebar.js")
      #html.script(src: "/scripts/book.js")
    ]
  },
)
