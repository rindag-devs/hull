#!/usr/bin/env bash
set -euo pipefail

if (($# != 0)); then
  printf 'usage: %s\n' "$0" >&2
  exit 2
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(git -C "$script_dir" rev-parse --show-toplevel)
skills_root="$repository_root/docs/.well-known/agent-skills"
index_path="$skills_root/index.json"

for command in awk find git gzip install jq sha256sum sort tar; do
  if ! command -v "$command" >/dev/null; then
    printf 'required command not found: %s\n' "$command" >&2
    exit 1
  fi
done

stage=$(mktemp -d "${TMPDIR:-/tmp}/hull-agent-skills.XXXXXX")
cleanup() {
  rm -rf -- "$stage"
}
trap cleanup EXIT

working_index="$stage/index.json"
cp -- "$index_path" "$working_index"

declare -a archive_targets=()
declare -a staged_archives=()
skill_count=$(jq -er '.skills | length' "$working_index")

for ((index = 0; index < skill_count; index++)); do
  name=$(jq -er ".skills[$index].name" "$working_index")
  type=$(jq -er ".skills[$index].type" "$working_index")
  url=$(jq -er ".skills[$index].url" "$working_index")

  case "$url" in
  /.well-known/agent-skills/*) ;;
  *)
    printf 'skill %s has unsupported URL: %s\n' "$name" "$url" >&2
    exit 1
    ;;
  esac
  if [[ "$url" == *..* ]]; then
    printf 'skill %s URL must not contain ..: %s\n' "$name" "$url" >&2
    exit 1
  fi

  artifact_path="$repository_root/docs$url"
  case "$type" in
  archive)
    if [[ "$artifact_path" != *.tar.gz ]]; then
      printf 'archive skill %s must use a .tar.gz URL\n' "$name" >&2
      exit 1
    fi
    source_path=${artifact_path%.tar.gz}
    if [[ ! -d "$source_path" ]]; then
      printf 'archive source directory not found for skill %s: %s\n' "$name" "$source_path" >&2
      exit 1
    fi

    mapfile -d '' roots < <(
      find "$source_path" -mindepth 1 -maxdepth 1 -printf '%f\0' | LC_ALL=C sort -z
    )
    if ((${#roots[@]} == 0)); then
      printf 'archive source directory is empty for skill %s\n' "$name" >&2
      exit 1
    fi

    staged_archive="$stage/archive-$index.tar.gz"
    tar \
      --sort=name \
      --mtime='@0' \
      --owner=0 \
      --group=0 \
      --numeric-owner \
      --format=gnu \
      -C "$source_path" \
      -cf - \
      -- "${roots[@]}" |
      gzip -n -9 >"$staged_archive"
    artifact_for_digest=$staged_archive
    archive_targets+=("$artifact_path")
    staged_archives+=("$staged_archive")
    ;;
  skill-md)
    if [[ ! -f "$artifact_path" ]]; then
      printf 'skill file not found for %s: %s\n' "$name" "$artifact_path" >&2
      exit 1
    fi
    artifact_for_digest=$artifact_path
    ;;
  *)
    printf 'skill %s has unsupported type: %s\n' "$name" "$type" >&2
    exit 1
    ;;
  esac

  digest=$(sha256sum "$artifact_for_digest" | awk '{print $1}')
  next_index="$stage/index-$index.json"
  jq --arg digest "sha256:$digest" ".skills[$index].digest = \$digest" \
    "$working_index" >"$next_index"
  mv -- "$next_index" "$working_index"
done

jq -e '
  .skills | all(
    .digest | test("^sha256:[0-9a-f]{64}$")
  )
' "$working_index" >/dev/null

for ((index = 0; index < ${#archive_targets[@]}; index++)); do
  install -m 0644 "${staged_archives[$index]}" "${archive_targets[$index]}"
done
install -m 0644 "$working_index" "$index_path"
