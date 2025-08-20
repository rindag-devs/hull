{
  pkgs,
  hullPkgs,
}:

{
  # Compiles a WASM file to a native CWASM artifact for faster execution.
  cwasm =
    { name, wasm }:
    pkgs.runCommandLocal "hull-cwasm-${name}.cwasm"
      {
        nativeBuildInputs = [ hullPkgs.default ];
      }
      ''
        cp ${wasm} wasm
        hull compile-cwasm wasm cwasm
        cp cwasm $out
      '';
}
