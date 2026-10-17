#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bucket_name=${CF_R2_BUCKET:-cli-porter}

if (($# > 0)); then
  binaries=("$@")
else
  binaries=(
    deepwiki
    deepwiki.exe
    microsoft-learn
    microsoft-learn.exe
    svelte
    svelte.exe
    exa
    exa.exe
  )
fi

for binary in "${binaries[@]}"; do
  file_path=$binary
  if [[ "$file_path" != /* ]]; then
    file_path="$repo_root/$file_path"
  fi

  if [[ ! -f "$file_path" ]]; then
    printf 'Missing binary: %s\n' "$file_path" >&2
    exit 1
  fi

  object_key=$(basename "$file_path")
  content_type=application/octet-stream
  if [[ "$object_key" == *.exe ]]; then
    content_type=application/vnd.microsoft.portable-executable
  fi

  printf 'Uploading %s to %s/%s\n' "$file_path" "$bucket_name" "$object_key"
  cf r2 objects put "$object_key" \
    --bucket-name "$bucket_name" \
    --file "$file_path" \
    --content-type "$content_type"
done