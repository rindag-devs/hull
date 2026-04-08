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
  lib,
  gccNGPackages_15,
  llvmPackages,
  autoconf269,
  automake,
  libtool,
  libc,
  compiler-rt,
  runCommand,
}:

let
  wasmResourceDir = runCommand "wasm32-wasi-wasip1-resource-dir" { } ''
    mkdir -p $out/include $out/lib
    cp -r ${llvmPackages.clang-unwrapped.lib}/lib/clang/${lib.versions.major llvmPackages.clang.version}/include/. $out/include/
    cp -r ${compiler-rt}/lib/. $out/lib/
  '';
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "wasm32-wasi-wasip1-libstdcxx";

  inherit (gccNGPackages_15.libstdcxx) version src;

  nativeBuildInputs = [
    autoconf269
    automake
    libtool
    llvmPackages.clang-unwrapped
    llvmPackages.llvm
    llvmPackages.lld
  ];

  patches = [ ./wasm.patch ];

  postPatch = ''
    pushd libstdc++-v3
    autoreconf -v -i
    popd
  '';

  configurePhase = ''
    mkdir -p build
    cd build

    ../libstdc++-v3/configure \
      --build=${stdenvNoCC.buildPlatform.config} \
      --host=wasm32-wasip1 \
      --target=wasm32-wasip1 \
      --prefix=$out \
      --with-sysroot=${libc} \
      --disable-multilib \
      --disable-shared \
      --enable-static \
      --disable-libstdcxx-threads \
      --disable-libstdcxx-pch \
      --enable-clocale=generic \
      --enable-libstdcxx-allocator=new \
      --disable-libstdcxx-dual-abi \
      --libdir=$out/lib/wasm32-wasip1 \
      CC=clang \
      CXX=clang++ \
      AR="llvm-ar" \
      AS="llvm-as" \
      RANLIB="llvm-ranlib" \
      LD="lld" \
      NM="llvm-nm"
  '';

  env =
    let
      targetFlags = "--target=wasm32-wasi-wasip1 -mcpu=mvp --sysroot=${libc} -resource-dir=/${wasmResourceDir}";
      commonFlags = "-O2 -g -fno-exceptions ${targetFlags}";
      cxxFlags = "${commonFlags} -nostdlib++ -nostdinc++ -Wno-init-priority-reserved -Wno-invalid-constexpr";
    in
    {
      CFLAGS = commonFlags;
      CXXFLAGS = cxxFlags;
      CPPFLAGS = targetFlags;
    };

  enableParallelBuilding = true;

  meta = with lib; {
    description = "libstdc++ built for WebAssembly WASI";
    homepage = "https://gcc.gnu.org/libstdc++/";
    license = licenses.gpl3Plus;
    platforms = platforms.all;
  };
})
