{
  pkgs,
  tola,
  optionsDocs,
  system,
}:

let
  toc = import ./toc.nix;
  siteUrl = "https://hull.aberter0x3f.top";
  tocPages = [ toc.introduction ] ++ pkgs.lib.concatMap (section: section.pages) toc.sections;
  sourcePages = builtins.filter (page: page ? source) tocPages;
  generatedPages = builtins.filter (page: page ? generated) tocPages;
  extraPages = [
    {
      target = "404.typ";
      source = "404.typ";
    }
  ];

  typstString = builtins.toJSON;
  typstEntry = page: "(title: ${typstString page.title}, href: ${typstString page.href})";
  normalizedHref = href: if href == "/" then "/" else "${href}/";
  absoluteUrl = href: "${siteUrl}${normalizedHref href}";
  markdownPageLink = page: "- [${page.title}](${absoluteUrl page.href})";
  agentMirrorPath =
    page:
    let
      href = pkgs.lib.removePrefix "/" (normalizedHref page.href);
    in
    if href == "" then "index.typ" else "${pkgs.lib.removeSuffix "/" href}.typ";
  markdownSection = section: ''
    ## ${section.title}

    ${pkgs.lib.concatMapStringsSep "\n" markdownPageLink section.pages}
  '';
  typstSection = section: ''
    (
      title: ${typstString section.title},
      pages: (
        ${pkgs.lib.concatMapStringsSep ",\n      " typstEntry section.pages},
      ),
    )'';

  llmsTxt = pkgs.writeText "llms.txt" ''
    # Hull Documentation

    > Hull is a Nix-based framework for competitive programming problem authoring, runtime analysis, and packaging.

    This documentation is designed to be consumed by humans and language models. It is static HTML, organized by a single canonical table of contents, indexed by Pagefind, and published with a sitemap and explicit crawler policy.

    Canonical site: ${siteUrl}/
    Sitemap: ${siteUrl}/sitemap.xml
    Robots policy: ${siteUrl}/robots.txt
    LLM index: ${siteUrl}/llms.txt
    Agent skills index: ${siteUrl}/.well-known/agent-skills/index.json
    Documentation discovery skill: ${siteUrl}/.well-known/agent-skills/documentation/SKILL.md
    Source repository: https://github.com/rindag-devs/hull

    ## Use This Documentation For

    - Understanding Hull's problem and contest definitions.
    - Authoring `problem.nix` and `contest.nix` files.
    - Building validators, checkers, official solutions, generators, and package targets.
    - Reading generated Nix module option references for machine-checkable configuration details.

    ## Canonical Entry Point

    ${markdownPageLink toc.introduction}

    ${pkgs.lib.concatMapStringsSep "\n" markdownSection toc.sections}

    ## Reference Notes For LLMs

    - Prefer the generated options reference pages for exact option names, types, defaults, and semantics.
    - Prefer the Getting Started pages for workflow-level explanations and examples.
    - Treat the sitemap as the authoritative crawl list for published documentation pages.
    - The documentation source is Typst, but the published site is static HTML.
    - Do not infer undocumented options from examples; use the reference pages instead.

    ## Agent Content Negotiation

    Browser requests receive HTML by default. Agents may request source-oriented responses from any canonical documentation page by sending `Accept: text/markdown` or `Accept: text/x-typst`.

    - `Accept: text/markdown` returns the corresponding Typst source with `Content-Type: text/markdown; charset=utf-8` for compatibility with Markdown-for-agents clients.
    - `Accept: text/x-typst` returns the corresponding Typst source with `Content-Type: text/plain; charset=utf-8`.
    - Source-oriented responses include `x-agent-source-format: typst`.
    - The source mirror is also available under `/.well-known/agent-typst/`; for example, the homepage source is `/.well-known/agent-typst/index.typ`.

    ## Agent Discovery

    Agents may start from `llms.txt`, the sitemap, or the agent skills index. The documentation discovery skill describes the canonical crawl surfaces, source-oriented representations, and reference pages. These files are stable public discovery entry points:

    - ${siteUrl}/llms.txt
    - ${siteUrl}/.well-known/agent-skills/index.json
    - ${siteUrl}/.well-known/agent-skills/documentation/SKILL.md

    ## Crawl Policy

    This site intentionally exposes static documentation pages, `sitemap.xml`, `robots.txt`, and this `llms.txt` file for discovery. The documentation may be used for search, AI input, and AI training. The corresponding content signal is `ai-train=yes, search=yes, ai-input=yes`.
  '';

  navigation = pkgs.writeText "navigation.typ" ''
    #let introduction = ${typstEntry toc.introduction}

    #let nav-sections = (
      ${pkgs.lib.concatMapStringsSep ",\n  " typstSection toc.sections},
    )
  '';

  mkOptionsReferenceHeader =
    title: summary:
    pkgs.writeText "${pkgs.lib.strings.toLower (builtins.replaceStrings [ " " ] [ "-" ] title)}-header.typ" ''
      #import "/templates/page.typ": page

      #show: page.with(
        title: "${title}",
      )

      = ${title}

      ${summary}

    '';
  problemOptionsHeader = mkOptionsReferenceHeader "Problem Options Reference" (
    "This page is generated from Hull's problem Nix module options during the documentation build."
  );
  contestOptionsHeader = mkOptionsReferenceHeader "Contest Options Reference" (
    "This page is generated from Hull's contest Nix module options during the documentation build."
  );
  generatedDocs = {
    problemModuleOptions = {
      header = problemOptionsHeader;
      source = optionsDocs.problemModule;
    };
    contestModuleOptions = {
      header = contestOptionsHeader;
      source = optionsDocs.contestModule;
    };
  };

  copySourcePage = page: ''
    mkdir -p "$(dirname "content/${page.target}")"
    cp ${./content}/${page.source} "content/${page.target}"
  '';
  writeGeneratedPage =
    page:
    let
      generated = generatedDocs.${page.generated};
    in
    ''
      mkdir -p "$(dirname "content/${page.target}")"
      cat ${generated.header} > "content/${page.target}"
      ${pkgs.pandoc}/bin/pandoc -f commonmark -t typst ${generated.source} >> "content/${page.target}"
    '';
  writeSourceAgentMirror = page: ''
    mkdir -p "$(dirname "public/.well-known/agent-typst/${agentMirrorPath page}")"
    cp ${./content}/${page.source} "public/.well-known/agent-typst/${agentMirrorPath page}"
  '';
  writeGeneratedAgentMirror = page: ''
    mkdir -p "$(dirname "public/.well-known/agent-typst/${agentMirrorPath page}")"
    cp "content/${page.target}" "public/.well-known/agent-typst/${agentMirrorPath page}"
  '';
  writeContentPages = pkgs.lib.concatStringsSep "\n" (
    (map copySourcePage (sourcePages ++ extraPages)) ++ (map writeGeneratedPage generatedPages)
  );
  writeAgentMirrors = pkgs.lib.concatStringsSep "\n" (
    (map writeSourceAgentMirror sourcePages) ++ (map writeGeneratedAgentMirror generatedPages)
  );
in
pkgs.runCommandLocal "hull-docs" { } ''
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME"
  cp -R ${./.}/. .
  chmod -R u+w .
  rm -rf content
  mkdir -p content
  cp ${navigation} templates/navigation.typ
  ${writeContentPages}
  ${tola.packages.${system}.default}/bin/tola build
  cp public/404/index.html "$TMPDIR/404.html"
  rm -rf public/404
  substituteInPlace public/sitemap.xml \
    --replace-fail '<url><loc>${siteUrl}/404/</loc></url>' ""
  cp robots.txt public/robots.txt
  cp _headers public/_headers
  cp _worker.js public/_worker.js
  mkdir -p public/.well-known
  cp -R .well-known/. public/.well-known/
  cp ${llmsTxt} public/llms.txt
  mkdir -p public/.well-known/agent-typst
  ${writeAgentMirrors}
  cp ${./content/404.typ} public/.well-known/agent-typst/404.typ
  ${pkgs.pagefind}/bin/pagefind --site public
  cp "$TMPDIR/404.html" public/404.html
  cp -R ./public "$out"
''
