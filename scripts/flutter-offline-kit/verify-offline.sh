#!/usr/bin/env bash
set -euo pipefail
PREFIX="${FLUTTER_OFFLINE_PREFIX:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
source "$PREFIX/env.sh"
export FLUTTER_STORAGE_BASE_URL="http://127.0.0.1:9"
export HTTP_PROXY="http://127.0.0.1:9"
export HTTPS_PROXY="http://127.0.0.1:9"
export http_proxy="$HTTP_PROXY"
export https_proxy="$HTTPS_PROXY"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -a "$PREFIX/offline_starter" "$WORK/app"
cd "$WORK/app"
flutter pub get --offline
rm -rf build
flutter build linux --release --no-pub
printf 'Offline Flutter Linux release build succeeded.\n'
