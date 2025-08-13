{
  pkgs,
  hullPkgs,
  hull,
}:

{
  wasm =
    { languages, includes, ... }:
    { src, language }:
    languages.${language}.compile {
      name = "hull-wasm-${builtins.baseNameOf src}";
      inherit src includes;
    };

  cwasm =
    { name, wasm }:
    pkgs.runCommandLocal "hull-cwasm-${name}" {
      nativeBuildInputs = [ hullPkgs.default ];
    } "hull compile-cwasm ${wasm} $out";
}
