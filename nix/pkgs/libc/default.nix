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
  fetchFromGitHub,
  cmake,
  ninja,
  llvmPackages,
  compiler-rt,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "wasm32-wasi-wasip1-compiler-libc";
  version = "30";

  src = fetchFromGitHub {
    owner = "WebAssembly";
    repo = "wasi-libc";
    rev = "wasi-sdk-${finalAttrs.version}";
    hash = "sha256-TDCe7wzx78ictXhc7HafIp5P2yYbgZevxIg+jhn9u7A=";
  };

  nativeBuildInputs = [
    cmake
    ninja
    llvmPackages.clang-unwrapped
    llvmPackages.llvm
  ];

  patches = [ ./no_bulk_memory.patch ];

  cmakeFlags = [
    "-DCMAKE_SYSTEM_NAME=WASI"
    "-DCMAKE_SYSTEM_VERSION=1"
    "-DCMAKE_SYSTEM_PROCESSOR=wasm32"
    "-DCMAKE_C_COMPILER=clang"
    "-DCMAKE_C_COMPILER_TARGET=wasm32-wasi-wasip1"
    "-DCMAKE_AR=${llvmPackages.llvm}/bin/llvm-ar"
    "-DCMAKE_NM=${llvmPackages.llvm}/bin/llvm-nm"
    "-DCMAKE_RANLIB=${llvmPackages.llvm}/bin/llvm-ranlib"
    "-DCMAKE_C_FLAGS=-mcpu=mvp"
    "-DCMAKE_ASM_FLAGS=-mcpu=mvp"
    "-DBUILTINS_LIB=${compiler-rt}"
    "-DCMAKE_C_COMPILER_WORKS=ON"
    "-DBUILD_SHARED=OFF"
    "-DSETJMP=OFF"
    "-DSIMD=OFF"
    "-DBUILD_TESTS=OFF"
    "-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld"
    "-USE_WASM_COMPONENT_LD=OFF"
  ];

  enableParallelBuilding = true;

  installTargets = [ "install" ];
})
