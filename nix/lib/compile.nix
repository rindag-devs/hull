{
  pkgs,
  hullPkgs,
  hull,
}:

{
  wasm =
    { languages, ... }:
    { src, language }:
    languages."${language}".compile {
      name = "hull-wasm-${builtins.baseNameOf src}";
      inherit src;
    };

  cwasm =
    { name, wasm }:
    pkgs.runCommandLocal "hull-cwasm-${name}" {
      nativeBuildInputs = [ hullPkgs.default ];
    } "hull compile-cwasm ${wasm} $out";
}
