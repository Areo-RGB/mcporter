#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="${FLUTTER_OFFLINE_PAYLOAD_DIR:-$HERE}"
PREFIX="${FLUTTER_OFFLINE_PREFIX:-$HOME/.local/share/flutter-offline-3.44.8}"
SKIP_NATIVE=0

for arg in "$@"; do
  case "$arg" in
    --skip-native) SKIP_NATIVE=1 ;;
    --help|-h)
      echo "Usage: ./install.sh [--skip-native]"
      echo "Environment: FLUTTER_OFFLINE_PAYLOAD_DIR, FLUTTER_OFFLINE_PREFIX"
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "This kit requires x86_64/amd64 Linux." >&2
  exit 1
fi
if [[ ! -r /etc/os-release ]] || ! grep -q '^ID=debian' /etc/os-release || ! grep -Eq '^VERSION_ID="?13' /etc/os-release; then
  echo "This native package bundle targets Debian 13. Use --skip-native only when compatible prerequisites are already installed." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assemble() {
  local base="$1"
  local dest="$WORK/$base"
  if [[ -f "$PAYLOAD_DIR/$base" ]]; then
    cp "$PAYLOAD_DIR/$base" "$dest"
  else
    shopt -s nullglob
    local parts=("$PAYLOAD_DIR/$base".part-*)
    shopt -u nullglob
    if [[ ${#parts[@]} -eq 0 ]]; then
      echo "Missing payload: $base or $base.part-* in $PAYLOAD_DIR" >&2
      exit 1
    fi
    IFS=$'\n' parts=($(printf '%s\n' "${parts[@]}" | sort))
    unset IFS
    cat "${parts[@]}" > "$dest"
  fi
  printf '%s\n' "$dest"
}

if [[ -f "$HERE/PAYLOAD_SHA256SUMS" ]]; then
  (cd "$PAYLOAD_DIR" && sha256sum --check "$HERE/PAYLOAD_SHA256SUMS")
fi

if [[ "$SKIP_NATIVE" -eq 0 ]]; then
  native_archive="$(assemble flutter-native-debs-debian13-amd64.tar.zst)"
  mkdir -p "$WORK/debs"
  tar --extract --zstd --file "$native_archive" --directory "$WORK/debs"
  if [[ "$EUID" -eq 0 ]]; then
    SUDO=()
  elif command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
  else
    echo "Root privileges or sudo are required to install native .deb dependencies." >&2
    exit 1
  fi
  "${SUDO[@]}" dpkg -i "$WORK"/debs/*.deb || "${SUDO[@]}" apt-get -y --no-download -f install
fi

sdk_archive="$(assemble flutter-sdk-3.44.8-linux-x64-debian13.tar.zst)"
pub_archive="$(assemble flutter-pub-cache-3.44.8-desktop.tar.zst)"
samples_archive="$(assemble flutter-desktop-samples-3.44.8.tar.zst)"

mkdir -p "$PREFIX"
tar --extract --zstd --file "$sdk_archive" --directory "$PREFIX"
tar --extract --zstd --file "$pub_archive" --directory "$PREFIX"
tar --extract --zstd --file "$samples_archive" --directory "$PREFIX"
cp "$HERE/env.sh" "$HERE/verify-offline.sh" "$HERE/new-app.sh" "$PREFIX/"

printf '\nInstalled under: %s\n' "$PREFIX"
printf 'Activate with:\n  source %q\n' "$PREFIX/env.sh"
printf 'Verify with:\n  %q\n' "$PREFIX/verify-offline.sh"
