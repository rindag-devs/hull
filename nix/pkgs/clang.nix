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
  pkgs,
  llvmPackages ? pkgs.llvmPackages,
  sysroot,
  compiler-rt,
}:

let
  commonFlags = [
    "--target=wasm32-wasi-wasip1"
    "-mcpu=mvp"
    "--sysroot=${sysroot}"
  ];

  lldBinPath = lib.makeBinPath [ llvmPackages.lld ];
in
pkgs.symlinkJoin {
  name = "wasm32-wasi-wasip1-clang-${llvmPackages.clang.version}";

  paths = [
    (pkgs.writeShellScriptBin "wasm32-wasi-wasip1-clang" ''
      wrapper_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
      exec ${llvmPackages.clang-unwrapped}/bin/clang \
        -resource-dir="$wrapper_dir/../resource-dir" \
        ${lib.escapeShellArgs commonFlags} \
        "$@"
    '')
    (pkgs.writeShellScriptBin "wasm32-wasi-wasip1-clang++" ''
      export PATH=${lib.escapeShellArg lldBinPath}:$PATH
      wrapper_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
      exec ${llvmPackages.clang-unwrapped}/bin/clang++ \
        -stdlib=libstdc++ \
        -nostdlib++ \
        -lstdc++ \
        -lsupc++ \
        -fno-exceptions \
        -resource-dir="$wrapper_dir/../resource-dir" \
        ${lib.escapeShellArgs commonFlags} \
        "$@"
    '')
  ];

  postBuild = ''
    mkdir -p $out/resource-dir
    ln -s ${llvmPackages.clang-unwrapped.lib}/lib/clang/${lib.versions.major llvmPackages.clang.version}/include $out/resource-dir/include
    ln -s ${compiler-rt}/lib $out/resource-dir/lib
  '';

  meta = {
    description = "Wrapper for clang / clang++ to compile for wasm judge";
    platforms = lib.platforms.all;
    mainProgram = "wasm32-wasi-wasip1-clang";
  };
}
