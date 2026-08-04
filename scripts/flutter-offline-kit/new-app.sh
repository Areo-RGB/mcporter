#!/usr/bin/env bash
set -euo pipefail
PREFIX="${FLUTTER_OFFLINE_PREFIX:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
source "$PREFIX/env.sh"
DEST="${1:?Usage: new-app.sh DESTINATION [PROJECT_NAME]}"
NAME="${2:-$(basename "$DEST" | tr '-' '_')}"
flutter create --platforms=linux --no-pub --project-name "$NAME" "$DEST"
(
  cd "$DEST"
  flutter pub get --offline
)
printf 'Created offline Linux desktop app: %s\n' "$DEST"
