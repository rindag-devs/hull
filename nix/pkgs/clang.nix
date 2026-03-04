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
  lib,
  llvmPackages,
  stdenvNoCC,
  makeWrapper,
  sysroot,
  compiler-rt,
}:

stdenvNoCC.mkDerivation {
  pname = "wasm32-wasi-wasip1-clang";
  version = llvmPackages.clang.version;

  nativeBuildInputs = [
    makeWrapper
  ];

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontCheck = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    mkdir -p $out/resource-dir

    ln -s ${llvmPackages.clang-unwrapped.lib}/lib/clang/${lib.versions.major llvmPackages.clang.version}/include $out/resource-dir/include
    ln -s ${compiler-rt}/lib $out/resource-dir/lib

    local common_flags=(
      "--target=wasm32-wasi-wasip1"
      "-mcpu=mvp"
      "--sysroot=${sysroot}"
      "-resource-dir=$out/resource-dir"
    )

    makeWrapper ${llvmPackages.clang-unwrapped}/bin/clang $out/bin/wasm32-wasi-wasip1-clang \
      --add-flags "''${common_flags[*]}" \
      --prefix PATH : ${lib.makeBinPath [ llvmPackages.lld ]}

    makeWrapper ${llvmPackages.clang-unwrapped}/bin/clang++ $out/bin/wasm32-wasi-wasip1-clang++ \
      --add-flags "-stdlib=libstdc++" \
      --add-flags "-nostdlib++" \
      --add-flags "-lstdc++" \
      --add-flags "-lsupc++" \
      --add-flags "-fno-exceptions" \
      --add-flags "''${common_flags[*]}" \
      --prefix PATH : ${lib.makeBinPath [ llvmPackages.lld ]}

    runHook postInstall
  '';

  meta = {
    description = "Wrapper for clang / clang++ to compile for wasm judge";
    platforms = lib.platforms.all;
    mainProgram = "wasm32-wasi-wasip1-clang";
  };
}
