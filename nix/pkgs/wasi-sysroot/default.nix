{
  stdenvNoCC,
  fetchurl,
}:

let
  version = "26_judge";
in
stdenvNoCC.mkDerivation {
  pname = "wasi-sysroot";

  inherit version;

  src = fetchurl {
    url = "https://github.com/aberter0x3f/wasi-sdk/releases/download/wasi-sdk-${version}/wasi-sysroot-${version}.0.tar.gz";
    hash = "sha256-sXTI2dZHFXDlcL9aqmQuEct2tnGC38aVUUNC3o1Z1Us=";
  };

  installPhase = ''
    cp -r . $out
  '';
}
