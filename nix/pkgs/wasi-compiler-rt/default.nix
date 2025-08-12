{
  stdenvNoCC,
  fetchurl,
}:

let
  version = "26_judge";
in
stdenvNoCC.mkDerivation {
  pname = "wasi-compiler-rt";

  inherit version;

  src = fetchurl {
    url = "https://github.com/aberter0x3f/wasi-sdk/releases/download/wasi-sdk-${version}/libclang_rt-${version}.0.tar.gz";
    hash = "sha256-8t6MT6fd3zQ1EiqdlAqNPHmKKJqRrD+1BZHzdu0IC/I=";
  };

  installPhase = ''
    mkdir -p $out/lib
    cp -r wasm32-unknown-wasip1 $out/lib/wasm32-unknown-wasip1
    ln -s $out/lib/wasm32-unknown-wasip1 $out/lib/wasm32-wasi-wasip1
  '';
}
