/*
  This file is part of Hull.

  Hull is free software: you can redistribute it and/or modify it under the terms of the GNU
  Lesser General Public License as published by the Free Software Foundation, either version 3 of
  the License, or (at your option) any later version.

  Hull is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
  the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser
  General Public License for more details.

  You should have received a copy of the GNU Lesser General Public License along with Hull. If
  not, see <https://www.gnu.org/licenses/>.
*/

{
  stdenvNoCC,
  llvmPackages,
  cmake,
  ninja,
  lib,
  python3,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "wasm32-wasi-wasip1-compiler-rt";

  inherit (llvmPackages.compiler-rt) version src;

  sourceRoot = "${finalAttrs.src.name}/compiler-rt";

  nativeBuildInputs = [
    cmake
    ninja
    python3
    llvmPackages.clang-unwrapped
    llvmPackages.llvm
  ];

  cmakeFlags = [
    "-DCMAKE_SYSTEM_NAME=WASI"
    "-DCMAKE_SYSTEM_VERSION=1"
    "-DCMAKE_SYSTEM_PROCESSOR=wasm32"
    "-DCMAKE_SYSROOT=/var/empty"
    "-DCMAKE_C_COMPILER=clang"
    "-DCMAKE_CXX_COMPILER=clang++"
    "-DCMAKE_C_COMPILER_TARGET=wasm32-wasi-wasip1"
    "-DCMAKE_AR=${llvmPackages.llvm}/bin/llvm-ar"
    "-DCMAKE_NM=${llvmPackages.llvm}/bin/llvm-nm"
    "-DCMAKE_RANLIB=${llvmPackages.llvm}/bin/llvm-ranlib"
    "-DCMAKE_C_FLAGS=-mcpu=mvp"
    "-DCOMPILER_RT_BAREMETAL_BUILD=ON"
    "-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON"
    "-DCOMPILER_RT_INCLUDE_TESTS=OFF"
    "-DCOMPILER_RT_BUILD_XRAY=OFF"
    "-DCOMPILER_RT_BUILD_LIBFUZZER=OFF"
    "-DCOMPILER_RT_BUILD_PROFILE=OFF"
    "-DCOMPILER_RT_BUILD_SANITIZERS=OFF"
    "-DCOMPILER_RT_BUILD_ORC=OFF"
    "-DCOMPILER_RT_BUILD_CTX_PROFILE=OFF"
    "-DCOMPILER_RT_BUILD_MEMPROF=OFF"
    "-DCOMPILER_RT_BUILD_GWP_ASAN=OFF"
    "-DCOMPILER_RT_BUILD_CRT=OFF"
    "-DCMAKE_C_COMPILER_WORKS=ON"
    "-DCMAKE_CXX_COMPILER_WORKS=ON"
    "-DCOMPILER_RT_OS_DIR=wasm32-wasi-wasip1"
    "-DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON"
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib
    cp -r lib/wasm32-wasi-wasip1 $out/lib/
    runHook postInstall
  '';

  enableParallelBuilding = true;

  meta = with lib; {
    description = "LLVM compiler-rt built for WebAssembly WASI, compiled with -mcpu=mvp";
    homepage = "https://compiler-rt.llvm.org/";
    license = with lib.licenses; [
      mit
      ncsa
    ];
    platforms = platforms.all;
  };
})
