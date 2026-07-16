#!/bin/sh
set -eu

case $(uname -m) in
x86_64)
  local_suffix=X86_64
  cross_suffix=Aarch64
  local_cnoi_target=cnoiParticipantX86_64
  cross_cnoi_target=cnoiParticipantAarch64
  local_machine='Advanced Micro Devices X86-64'
  cross_machine='AArch64'
  ;;
aarch64)
  local_suffix=Aarch64
  cross_suffix=X86_64
  local_cnoi_target=cnoiParticipantAarch64
  cross_cnoi_target=cnoiParticipantX86_64
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
  cargo run -- build -p test.aPlusB --target "$target" \
    --out-link "$root/artifact" --stop-on-failure
  test -L "$root/artifact"
  mkdir "$root/package"
  if [ -d "$root/artifact" ]; then
    cp -R -P "$root/artifact"/. "$root/package"/
  else
    7zz x -o"$root/package" "$root/artifact" >/dev/null
  fi
}

build_contest_target() {
  root=$1
  target=$2
  cargo run -- build-contest -c test.aPlusBContest --target "$target" \
    --out-link "$root/artifact" --stop-on-failure
  test -L "$root/artifact"
  mkdir "$root/package"
  case $(readlink -f "$root/artifact") in
  *.tar.zst) tar --zstd -C "$root/package" -xf "$root/artifact" ;;
  *.zip) 7zz x -o"$root/package" "$root/artifact" >/dev/null ;;
  *)
    printf 'unsupported contest archive: %s\n' "$(readlink -f "$root/artifact")" >&2
    return 1
    ;;
  esac
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
  marker=$(mktemp "$directory/.hull-machines.XXXXXX")
  header=$(mktemp "$directory/.hull-elf-header.XXXXXX")
  find "$directory" -type f -perm /111 ! -path "$marker" ! -path "$header" >"$marker"
  found=0
  while IFS= read -r candidate; do
    if readelf -h "$candidate" >"$header" 2>/dev/null; then
      if ! grep -F "Machine:                           $machine" "$header" >/dev/null; then
        rm -f "$marker" "$header"
        return 1
      fi
      found=1
    fi
  done <"$marker"
  rm -f "$marker" "$header"
  test "$found" -eq 1
}

require_static_machine() {
  executable=$1
  machine=$2
  readelf -h "$executable" | grep -F "Machine:                           $machine" >/dev/null
  ! readelf -l "$executable" | grep -F 'Requesting program interpreter' >/dev/null
  readelf -d "$executable" | grep -F 'There is no dynamic section in this file.' >/dev/null
}

extract_zstd_archive() {
  archive=$1
  destination=$2
  root=$3
  temporary_tar=$(mktemp "$root/archive.XXXXXX.tar")
  if ! 7zz x -so "$archive" >"$temporary_tar"; then
    rm -f "$temporary_tar"
    return 1
  fi
  if ! tar -C "$destination" -xf "$temporary_tar"; then
    rm -f "$temporary_tar"
    return 1
  fi
  rm -f "$temporary_tar"
}

require_archive_machines() {
  archive=$1
  machine=$2
  root=$3
  mkdir "$root/runtime"
  tar -C "$root/runtime" -xJf "$archive"
  require_machines "$root/runtime" "$machine"
}

require_zstd_archive_machines() {
  archive=$1
  machine=$2
  root=$3
  mkdir "$root/runtime"
  extract_zstd_archive "$archive" "$root/runtime" "$root"
  require_machines "$root/runtime" "$machine"
}

check_hydro_structure() {
  package=$1
  require_executable "$package/testdata/compile.sh"
  require_executable "$package/testdata/execute.sh"
  require_executable "$package/testdata/proot"
  require_executable "$package/testdata/busybox"
  require_executable "$package/testdata/zstd"
  require_file "$package/testdata/hull-bundle.tar.zst"
  require_file "$package/testdata/hull-runtime-store.tar.zst"
  require_file "$package/problem.yaml"
  require_file "$package/testdata/config.yaml"
  jq -e '.user_extra_files == [
    "compile.sh",
    "execute.sh",
    "proot",
    "busybox",
    "zstd",
    "hull-bundle.tar.zst",
    "hull-runtime-store.tar.zst"
  ]' "$package/testdata/config.yaml" >/dev/null
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
  require_file "$package/judger"
  require_file "$package/busybox"
  require_file "$package/zstd"
  require_file "$package/problem.conf"
  require_file "$package/hull-bundle/problem.json"
  require_file "$package/hull-bundle/uoj-language-config.json"
  require_file "$package/hull-bundle/supervisor.conf"
  require_file "$package/hull-bundle/nix-store.tar.zst"
  require_file "$package/hull-bundle/solutions/std.20.cpp"
}

test_hydro() {
  root=$1
  build_target "$root" "hydro$local_suffix"
  check_hydro_structure "$root/package"
  require_static_machine "$root/package/testdata/proot" "$local_machine"
  require_static_machine "$root/package/testdata/busybox" "$local_machine"
  require_static_machine "$root/package/testdata/zstd" "$local_machine"
  require_zstd_archive_machines "$root/package/testdata/hull-runtime-store.tar.zst" "$local_machine" "$root"

  mkdir "$root/bundle"
  extract_zstd_archive "$root/package/testdata/hull-bundle.tar.zst" "$root/bundle" "$root"
  mkdir "$root/work"
  cp "$root/bundle/bundle/solutions/std.20.cpp" "$root/work/foo.cpp"
  hydro_language=$(jq -r '[.hydroToHullLanguageMap | to_entries[] | select(.value == "cpp.20") | .key][0] // empty' \
    "$root/bundle/bundle/hydro-language-map.json")
  test -n "$hydro_language"
  bash_path=$(command -v bash)
  (
    cd "$root/work"
    PATH=/nonexistent HYDRO_LANG="$hydro_language" "$bash_path" "$root/package/testdata/compile.sh"
    PATH=/nonexistent "$bash_path" "$root/package/testdata/execute.sh" >report.txt
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
  require_static_machine "$root/package/judger" "$local_machine"
  require_static_machine "$root/package/busybox" "$local_machine"
  require_static_machine "$root/package/zstd" "$local_machine"
  require_zstd_archive_machines "$root/package/hull-bundle/nix-store.tar.zst" "$local_machine" "$root"

  chmod 0644 \
    "$root/package/judger" \
    "$root/package/busybox" \
    "$root/package/zstd"
  test ! -x "$root/package/judger"
  test ! -x "$root/package/busybox"
  test ! -x "$root/package/zstd"
  judger_inode=$(stat -c '%i' "$root/package/judger")
  busybox_inode=$(stat -c '%i' "$root/package/busybox")
  zstd_inode=$(stat -c '%i' "$root/package/zstd")
  make -C "$root/package" >/dev/null
  test "$(stat -c '%a' "$root/package/judger")" = 755
  test "$(stat -c '%a' "$root/package/busybox")" = 755
  test "$(stat -c '%a' "$root/package/zstd")" = 755
  test "$(stat -c '%i' "$root/package/judger")" != "$judger_inode"
  test "$(stat -c '%i' "$root/package/busybox")" != "$busybox_inode"
  test "$(stat -c '%i' "$root/package/zstd")" != "$zstd_inode"
  require_executable "$root/package/judger"
  require_executable "$root/package/busybox"
  require_executable "$root/package/zstd"
  mkdir "$root/main" "$root/work" "$root/result"
  cp "$root/package/hull-bundle/solutions/std.20.cpp" "$root/work/answer.code"
  printf '%s\n' 'answer_language C++20' >"$root/work/submission.conf"
  "$root/package/judger" "$root/main" "$root/work" "$root/result" "$root/package"
  grep -Fx 'score 100' "$root/result/result.txt" >/dev/null
  grep -E '^time [0-9]+$' "$root/result/result.txt" >/dev/null
  grep -E '^memory [0-9]+$' "$root/result/result.txt" >/dev/null
  grep -F '<subtask num="0" score="50" info="Accepted">' "$root/result/result.txt" >/dev/null
  grep -F '<subtask num="1" score="50" info="Accepted">' "$root/result/result.txt" >/dev/null
  ! grep -q '^error ' "$root/result/result.txt"
}

test_cnoi() {
  root=$1
  build_contest_target "$root" "$local_cnoi_target"
  require_executable "$root/package/selfeval"
  require_machines "$root/package/.selfeval-bundle/nix/store" "$local_machine"

  mkdir -p "$root/participant/aPlusB"
  cp nix/test/problem/aPlusB/solution/std.20.cpp "$root/participant/aPlusB/aPlusB.cpp"
  "$root/package/selfeval" "$root/participant" --json >"$root/report.json"
  jq -e '
    .score == .full_score and
    (.problems | length == 1) and
    .problems[0].name == "aPlusB" and
    .problems[0].score == .problems[0].full_score
  ' "$root/report.json" >/dev/null
}

test_cross_hydro() {
  root=$1
  build_target "$root" "hydro$cross_suffix"
  check_hydro_structure "$root/package"
  require_static_machine "$root/package/testdata/proot" "$cross_machine"
  require_static_machine "$root/package/testdata/busybox" "$cross_machine"
  require_static_machine "$root/package/testdata/zstd" "$cross_machine"
  require_zstd_archive_machines "$root/package/testdata/hull-runtime-store.tar.zst" "$cross_machine" "$root"
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
  require_static_machine "$root/package/judger" "$cross_machine"
  require_static_machine "$root/package/busybox" "$cross_machine"
  require_static_machine "$root/package/zstd" "$cross_machine"
  require_zstd_archive_machines "$root/package/hull-bundle/nix-store.tar.zst" "$cross_machine" "$root"
}

test_cross_cnoi() {
  root=$1
  build_contest_target "$root" "$cross_cnoi_target"
  require_executable "$root/package/selfeval"
  require_machines "$root/package/.selfeval-bundle/nix/store" "$cross_machine"
}

run_named_test() {
  case $1 in
  hydro) run_test hydro test_hydro ;;
  lemon) run_test lemon test_lemon ;;
  uoj) run_test uoj test_uoj ;;
  cnoi) run_test cnoi test_cnoi ;;
  cross-hydro) run_test cross-hydro test_cross_hydro ;;
  cross-lemon) run_test cross-lemon test_cross_lemon ;;
  cross-uoj) run_test cross-uoj test_cross_uoj ;;
  cross-cnoi) run_test cross-cnoi test_cross_cnoi ;;
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

for name in hydro lemon uoj cnoi cross-hydro cross-lemon cross-uoj cross-cnoi; do
  run_named_test "$name"
done
