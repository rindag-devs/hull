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
in
pkgs.runCommandLocal "wasm32-wasi-wasip1-clang-${llvmPackages.clang.version}" { } ''
  mkdir -p "$out/bin" "$out/resource-dir" "$out/toolchain/bin"

  cp ${llvmPackages.clang-unwrapped}/bin/clang "$out/toolchain/bin/clang"
  cp ${llvmPackages.clang-unwrapped}/bin/clang++ "$out/toolchain/bin/clang++"
  cp ${llvmPackages.lld}/bin/ld.lld "$out/toolchain/bin/ld.lld"
  cp ${llvmPackages.lld}/bin/wasm-ld "$out/toolchain/bin/wasm-ld"
  chmod +x "$out/toolchain/bin/clang" "$out/toolchain/bin/clang++" "$out/toolchain/bin/ld.lld" "$out/toolchain/bin/wasm-ld"

  install -Dm755 ${pkgs.writeShellScript "wasm32-wasi-wasip1-clang" ''
    wrapper_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
    exec "$wrapper_dir/../toolchain/bin/clang" \
      -resource-dir="$wrapper_dir/../resource-dir" \
      ${lib.escapeShellArgs commonFlags} \
      "$@"
  ''} "$out/bin/wasm32-wasi-wasip1-clang"

  install -Dm755 ${pkgs.writeShellScript "wasm32-wasi-wasip1-clang++" ''
    wrapper_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
    export PATH="$wrapper_dir/../toolchain/bin:$PATH"
    exec "$wrapper_dir/../toolchain/bin/clang++" \
      -stdlib=libstdc++ \
      -nostdlib++ \
      -lstdc++ \
      -lsupc++ \
      -fno-exceptions \
      -resource-dir="$wrapper_dir/../resource-dir" \
      ${lib.escapeShellArgs commonFlags} \
      "$@"
  ''} "$out/bin/wasm32-wasi-wasip1-clang++"

  ln -s ${llvmPackages.clang-unwrapped.lib}/lib/clang/${lib.versions.major llvmPackages.clang.version}/include "$out/resource-dir/include"
  ln -s ${compiler-rt}/lib "$out/resource-dir/lib"
''
