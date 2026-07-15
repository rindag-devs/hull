#!/bin/sh
set -eu

case $(uname -m) in
x86_64)
  local_suffix=X86_64
  cross_suffix=Aarch64
  local_machine='Advanced Micro Devices X86-64'
  cross_machine='AArch64'
  ;;
aarch64)
  local_suffix=Aarch64
  cross_suffix=X86_64
  local_machine='AArch64'
  cross_machine='Advanced Micro Devices X86-64'
  ;;
*)
  printf 'unsupported integration-test host: %s\n' "$(uname -m)" >&2
  exit 2
  ;;
esac

build_target() {
  root=$1
  target=$2
  nix develop --command cargo run -- build -p test.aPlusB --target "$target" \
    --out-link "$root/artifact" --stop-on-failure
  test -L "$root/artifact"
  mkdir "$root/package"
  if [ -d "$root/artifact" ]; then
    cp -R -P "$root/artifact"/. "$root/package"/
  else
    7zz x -o"$root/package" "$root/artifact" >/dev/null
  fi
}

run_test() {
  (
    name=$1
    function_name=$2
    root=$(mktemp -d "${TMPDIR:-/tmp}/hull-integration-${name}.XXXXXX")
    cleanup_root=0
    cleanup() {
      if [ "$cleanup_root" -eq 1 ]; then
        chmod -R u+rwX "$root" 2>/dev/null || true
        rm -rf "$root"
      else
        printf 'preserved integration test directory: %s\n' "$root" >&2
      fi
    }
    trap cleanup EXIT
    "$function_name" "$root"
    cleanup_root=1
  )
}

require_file() {
  test -f "$1"
}

require_executable() {
  test -x "$1"
}

require_machines() {
  directory=$1
  machine=$2
  marker=$(mktemp)
  find "$directory" -type f -perm /111 >"$marker"
  found=0
  while IFS= read -r candidate; do
    if readelf -h "$candidate" >/dev/null 2>&1; then
      if ! readelf -h "$candidate" | grep -F "Machine:                           $machine" >/dev/null; then
        rm "$marker"
        return 1
      fi
      found=1
    fi
  done <"$marker"
  rm "$marker"
  test "$found" -eq 1
}

require_archive_machines() {
  archive=$1
  machine=$2
  root=$3
  mkdir "$root/runtime"
  tar -C "$root/runtime" -xJf "$archive"
  require_machines "$root/runtime" "$machine"
}

check_hydro_structure() {
  package=$1
  require_executable "$package/testdata/compile.sh"
  require_executable "$package/testdata/execute.sh"
  require_executable "$package/testdata/proot"
  require_file "$package/testdata/hull-bundle.tar.xz"
  require_file "$package/testdata/hull-runtime-store.tar.xz"
  require_file "$package/problem.yaml"
  require_file "$package/testdata/config.yaml"
}

check_lemon_structure() {
  package=$1
  require_executable "$package/data/_hull/lemon-custom-compiler"
  require_executable "$package/data/_hull/lemon-custom-watcher"
  require_executable "$package/data/_hull/lemon-special-judge"
  test -d "$package/data/_hull/nix/store"
  require_file "$package/source/std/aPlusB/aPlusB.cpp"
  test -f "$package"/*.cdf
}

check_uoj_structure() {
  package=$1
  require_file "$package/Makefile"
  require_file "$package/judger.c"
  require_file "$package/judger.sh"
  require_file "$package/problem.conf"
  require_file "$package/hull-bundle/problem.json"
  require_file "$package/hull-bundle/uoj-language-config.json"
  require_file "$package/hull-bundle/nix-store.tar.xz"
  require_file "$package/hull-bundle/solutions/std.20.cpp"
}

test_hydro() {
  root=$1
  build_target "$root" "hydro$local_suffix"
  check_hydro_structure "$root/package"
  require_archive_machines "$root/package/testdata/hull-runtime-store.tar.xz" "$local_machine" "$root"

  mkdir "$root/bundle"
  tar -C "$root/bundle" -xJf "$root/package/testdata/hull-bundle.tar.xz"
  mkdir "$root/work"
  cp "$root/bundle/bundle/solutions/std.20.cpp" "$root/work/foo.cpp"
  hydro_language=$(nix develop --command jq -r '.hydroToHullLanguageMap | to_entries[] | select(.value == "cpp.20") | .key' \
    <"$root/bundle/bundle/hydro-language-map.json" | head -n 1)
  test -n "$hydro_language"
  (
    cd "$root/work"
    HYDRO_LANG="$hydro_language" "$root/package/testdata/compile.sh"
    "$root/package/testdata/execute.sh" >report.txt
  )
  grep -Fx '100' "$root/work/report.txt" >/dev/null
  grep -Fx 'accepted' "$root/work/report.txt" >/dev/null
  cc "$root/package/testdata/checker.c" -o "$root/checker"
  "$root/checker" /dev/null "$root/work/report.txt" /dev/null /dev/null "$root/work/score.txt" "$root/work/message.txt"
  grep -Fx '100' "$root/work/score.txt" >/dev/null
}

test_lemon() {
  root=$1
  build_target "$root" "lemon$local_suffix"
  check_lemon_structure "$root/package"

  mkdir "$root/submission" "$root/result"
  cp "$root/package/source/std/aPlusB/aPlusB.cpp" "$root/submission/aPlusB.cpp"
  (
    cd "$root/submission"
    "$root/package/data/_hull/lemon-custom-compiler" aPlusB.cpp
    : >error.txt
    "$root/package/data/_hull/lemon-custom-watcher" \
      HullBundle aPlusB.hullbundle '' "$root/result/report.txt" error.txt \
      1 100 128 1000 0 fallback.txt
  )
  grep -Fx '100' "$root/result/report.txt" >/dev/null
  grep -Fx 'accepted' "$root/result/report.txt" >/dev/null
  "$root/package/data/_hull/lemon-special-judge" \
    /dev/null "$root/result/report.txt" /dev/null 100 "$root/result/score.txt" "$root/result/message.txt"
  grep -Fx '100' "$root/result/score.txt" >/dev/null
}

test_uoj() {
  root=$1
  build_target "$root" "uoj$local_suffix"
  check_uoj_structure "$root/package"
  require_archive_machines "$root/package/hull-bundle/nix-store.tar.xz" "$local_machine" "$root"

  make -C "$root/package" >/dev/null
  mkdir "$root/work" "$root/result"
  cp "$root/package/hull-bundle/solutions/std.20.cpp" "$root/work/answer.code"
  printf '%s\n' 'answer_language C++20' >"$root/work/submission.conf"
  "$root/package/judger" "$root/package" "$root/work" "$root/result" "$root/package"
  grep -Fx 'score 100' "$root/result/result.txt" >/dev/null
  grep -E '^time [0-9]+$' "$root/result/result.txt" >/dev/null
  grep -E '^memory [0-9]+$' "$root/result/result.txt" >/dev/null
  grep -F '<subtask num="0" score="50" info="Accepted">' "$root/result/result.txt" >/dev/null
  grep -F '<subtask num="1" score="50" info="Accepted">' "$root/result/result.txt" >/dev/null
  ! grep -q '^error ' "$root/result/result.txt"
}

test_cross_hydro() {
  root=$1
  build_target "$root" "hydro$cross_suffix"
  check_hydro_structure "$root/package"
  require_machines "$root/package/testdata" "$cross_machine"
  require_archive_machines "$root/package/testdata/hull-runtime-store.tar.xz" "$cross_machine" "$root"
}

test_cross_lemon() {
  root=$1
  build_target "$root" "lemon$cross_suffix"
  check_lemon_structure "$root/package"
  require_machines "$root/package" "$cross_machine"
}

test_cross_uoj() {
  root=$1
  build_target "$root" "uoj$cross_suffix"
  check_uoj_structure "$root/package"
  require_archive_machines "$root/package/hull-bundle/nix-store.tar.xz" "$cross_machine" "$root"
}

run_named_test() {
  case $1 in
  hydro) run_test hydro test_hydro ;;
  lemon) run_test lemon test_lemon ;;
  uoj) run_test uoj test_uoj ;;
  cross-hydro) run_test cross-hydro test_cross_hydro ;;
  cross-lemon) run_test cross-lemon test_cross_lemon ;;
  cross-uoj) run_test cross-uoj test_cross_uoj ;;
  *)
    printf 'unknown integration test: %s\n' "$1" >&2
    return 2
    ;;
  esac
}

if [ "$#" -gt 0 ]; then
  for name in "$@"; do
    run_named_test "$name"
  done
  exit 0
fi

for name in hydro lemon uoj cross-hydro cross-lemon cross-uoj; do
  run_named_test "$name"
done
