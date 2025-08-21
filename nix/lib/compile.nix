{
  pkgs,
  hullPkgs,
  hull,
  ...
}:

let
  getLangInfo =
    src: languages:
    let
      languageName = hull.language.matchBaseName (baseNameOf src) languages;
      language = languages.${languageName};
    in
    {
      inherit languageName language;
    };
in
{
  # Compiles a source file to a WASM object file.
  object =
    {
      languages,
      name,
      src,
      includes,
    }:
    let
      langInfo = getLangInfo src languages;
    in
    langInfo.language.compile.object {
      inherit name src includes;
    };

  # Compiles a source file to a WASM executable file.
  executable =
    {
      languages,
      name,
      src,
      includes,
      extraObjects,
    }:
    let
      langInfo = getLangInfo src languages;
    in
    langInfo.language.compile.executable {
      inherit
        name
        src
        includes
        extraObjects
        ;
    };

  # Compiles a WASM file to a native CWASM artifact for faster execution.
  cwasm =
    { name, wasm }:
    pkgs.runCommandLocal "hull-cwasm-${name}.cwasm"
      {
        nativeBuildInputs = [ hullPkgs.default ];
      }
      ''
        hull compile-cwasm ${wasm} $out
      '';
}
