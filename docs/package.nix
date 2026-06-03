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

    ## Crawl Policy

    This site intentionally exposes static documentation pages, `sitemap.xml`, `robots.txt`, and this `llms.txt` file for discovery. If Cloudflare managed `robots.txt` is enabled, it may override or prepend crawler restrictions outside the repository-controlled build output.
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
  writeContentPages = pkgs.lib.concatStringsSep "\n" (
    (map copySourcePage (sourcePages ++ extraPages)) ++ (map writeGeneratedPage generatedPages)
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
  cp public/404/index.html public/404.html
  cp robots.txt public/robots.txt
  cp ${llmsTxt} public/llms.txt
  ${pkgs.pagefind}/bin/pagefind --site public
  cp -R ./public "$out"
''
