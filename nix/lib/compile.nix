{
  pkgs,
  hullPkgs,
  hull,
}:

{
  wasm =
    {
      name,
      languages,
      includes,
      ...
    }:
    { src, language }:
    languages.${language}.compile {
      name = "hull-wasm-${name}-${builtins.baseNameOf src}";
      inherit src includes;
    };

  cwasm =
    {
      name,
      ...
    }:
    { srcBaseName, wasm }:
    pkgs.runCommandLocal "hull-cwasm-${name}-${srcBaseName}"
      {
        nativeBuildInputs = [ hullPkgs.default ];
      }
      ''
        cp ${wasm} wasm
        hull compile-cwasm wasm cwasm
        cp cwasm $out
      '';
}
