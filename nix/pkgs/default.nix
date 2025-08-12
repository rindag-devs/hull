{
  pkgs,
}:

rec {
  wasi-compiler-rt = pkgs.callPackage ./wasi-compiler-rt { };
  wasi-sysroot = pkgs.callPackage ./wasi-sysroot { };
  wasm-judge-clang = pkgs.callPackage ./wasm-judge-clang {
    inherit wasi-compiler-rt wasi-sysroot;
  };
}
