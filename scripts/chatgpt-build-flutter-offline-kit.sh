#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="$(realpath -m "${1:-flutter-offline-output}")"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

FLUTTER_VERSION="3.44.8"
DART_VERSION="3.12.2"
FLUTTER_ARCHIVE="flutter_linux_3.44.8-stable.tar.xz"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${FLUTTER_ARCHIVE}"
FLUTTER_SHA256="672089e001571a9fbb209a495c583580c0c6c73ef98999264ba07fa93ace332d"

export FLUTTER_VERSION DART_VERSION FLUTTER_ARCHIVE FLUTTER_URL FLUTTER_SHA256

docker run --rm --platform linux/amd64 \
  -e FLUTTER_VERSION \
  -e DART_VERSION \
  -e FLUTTER_ARCHIVE \
  -e FLUTTER_URL \
  -e FLUTTER_SHA256 \
  -v "$OUTPUT_DIR:/out" \
  debian:13-slim bash -s <<'CONTAINER'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export CI=true
export FLUTTER_SUPPRESS_ANALYTICS=true

mkdir -p /out/native-debs/partial /work /opt/flutter-pub-cache /tmp/flutter-home

packages=(
  ca-certificates curl file git unzip xz-utils zip zstd
  clang cmake ninja-build pkg-config libgtk-3-dev libstdc++-14-dev libglu1-mesa
  libsecret-1-dev libayatana-appindicator3-dev libsqlite3-dev libnotify-dev
)

apt-get update
apt-get -y \
  -o Dir::Cache::archives=/out/native-debs \
  --download-only install --no-install-recommends "${packages[@]}"
apt-get -y \
  -o Dir::Cache::archives=/out/native-debs \
  --no-download install --no-install-recommends "${packages[@]}"

dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > /out/DEBIAN13_INSTALLED_PACKAGE_MANIFEST.tsv

cd /tmp
curl --fail --location --retry 5 --retry-delay 3 \
  --output "$FLUTTER_ARCHIVE" "$FLUTTER_URL"
printf '%s  %s\n' "$FLUTTER_SHA256" "$FLUTTER_ARCHIVE" | sha256sum --check -

tar --extract --xz --file "$FLUTTER_ARCHIVE" --directory /opt --no-same-owner
chown -R root:root /opt/flutter
git config --global --add safe.directory /opt/flutter

export HOME=/tmp/flutter-home
export PUB_CACHE=/opt/flutter-pub-cache
export PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:$PATH"

flutter --disable-analytics || true
dart --disable-analytics || true
flutter config \
  --enable-linux-desktop \
  --no-enable-android \
  --no-enable-ios \
  --no-enable-web \
  --no-enable-macos-desktop \
  --no-enable-windows-desktop
flutter precache --linux
flutter --version > /out/FLUTTER_VERSION.txt
flutter doctor -v | tee /out/FLUTTER_DOCTOR.txt

cd /work
flutter create --platforms=linux --project-name offline_starter offline_starter
cd /work/offline_starter
flutter pub get
flutter build linux --release --no-pub
mkdir -p /work/prebuilt-smoke-app
cp -a build/linux/x64/release/bundle/. /work/prebuilt-smoke-app/

cd /work
flutter create --platforms=linux --project-name desktop_toolbox desktop_toolbox
cd /work/desktop_toolbox
flutter pub add file_selector path_provider shared_preferences url_launcher
flutter pub get
flutter build linux --release --no-pub

# Prove that the cached SDK and packages can build with unreachable network endpoints.
export PUB_HOSTED_URL="http://127.0.0.1:9"
export FLUTTER_STORAGE_BASE_URL="http://127.0.0.1:9"
cd /work/offline_starter
flutter pub get --offline
rm -rf build
flutter build linux --release --no-pub
cp -a build/linux/x64/release/bundle/. /work/prebuilt-smoke-app/
printf 'Offline pub resolution and Linux release build succeeded.\n' > /out/OFFLINE_VERIFICATION.txt

rm -rf /work/offline_starter/build /work/desktop_toolbox/build
rm -rf /opt/flutter/.git/objects/pack/*.keep 2>/dev/null || true
find /out/native-debs -type f ! -name '*.deb' -delete

export ZSTD_CLEVEL=8
export ZSTD_NBTHREADS=0

tar --create --zstd --file "/out/flutter-sdk-${FLUTTER_VERSION}-linux-x64-debian13.tar.zst" \
  --directory /opt flutter

tar --create --zstd --file "/out/flutter-pub-cache-${FLUTTER_VERSION}-desktop.tar.zst" \
  --directory /opt flutter-pub-cache

tar --create --zstd --file "/out/flutter-desktop-samples-${FLUTTER_VERSION}.tar.zst" \
  --directory /work offline_starter desktop_toolbox prebuilt-smoke-app

tar --create --zstd --file "/out/flutter-native-debs-debian13-amd64.tar.zst" \
  --directory /out/native-debs .

mkdir -p /out/kit-meta
cat > /out/kit-meta/env.sh <<'ENV'
#!/usr/bin/env bash
_KIT_PREFIX="${FLUTTER_OFFLINE_PREFIX:-$HOME/.local/share/flutter-offline-3.44.8}"
export FLUTTER_ROOT="$_KIT_PREFIX/flutter"
export PUB_CACHE="$_KIT_PREFIX/flutter-pub-cache"
export PATH="$FLUTTER_ROOT/bin:$FLUTTER_ROOT/bin/cache/dart-sdk/bin:$PATH"
export FLUTTER_SUPPRESS_ANALYTICS=true
unset _KIT_PREFIX
ENV
chmod 0755 /out/kit-meta/env.sh

cat > /out/kit-meta/install.sh <<'INSTALL'
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
if [[ ! -r /etc/os-release ]] || ! grep -q '^ID=debian' /etc/os-release || ! grep -q '^VERSION_ID="\?13' /etc/os-release; then
  echo "This native package bundle targets Debian 13. Use --skip-native only if compatible prerequisites are already installed." >&2
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
    local parts=("$PAYLOAD_DIR/$base".part-*)
    if [[ ! -e "${parts[0]}" ]]; then
      echo "Missing payload: $base or $base.part-* in $PAYLOAD_DIR" >&2
      exit 1
    fi
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
INSTALL
chmod 0755 /out/kit-meta/install.sh

cat > /out/kit-meta/verify-offline.sh <<'VERIFY'
#!/usr/bin/env bash
set -euo pipefail
PREFIX="${FLUTTER_OFFLINE_PREFIX:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
source "$PREFIX/env.sh"
export PUB_HOSTED_URL="http://127.0.0.1:9"
export FLUTTER_STORAGE_BASE_URL="http://127.0.0.1:9"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -a "$PREFIX/offline_starter" "$WORK/app"
cd "$WORK/app"
flutter pub get --offline
flutter build linux --release --no-pub
"$WORK/app/build/linux/x64/release/bundle/offline_starter" --help >/dev/null 2>&1 || true
printf 'Offline Flutter Linux release build succeeded.\n'
VERIFY
chmod 0755 /out/kit-meta/verify-offline.sh

cat > /out/kit-meta/new-app.sh <<'NEWAPP'
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
NEWAPP
chmod 0755 /out/kit-meta/new-app.sh

cat > /out/kit-meta/README.md <<'README'
# Flutter Linux desktop offline kit

Target: Debian 13 (trixie), amd64/x86_64.

Included:

- Flutter 3.44.8 stable and Dart 3.12.2
- Linux desktop engine artifacts already precached
- Offline pub cache for the starter project and the official desktop packages `file_selector`, `path_provider`, `shared_preferences`, and `url_launcher`
- Debian 13 native development `.deb` packages, including Clang, CMake, Ninja, pkg-config, GTK 3 headers, and the C++ toolchain
- A minimal starter source tree, a desktop-toolbox source tree, and a prebuilt smoke-test application
- Installer, environment setup, offline verification, checksums, and new-project helper

## Install

Keep this metadata directory and all payload part files together, then run:

```bash
chmod +x install.sh
./install.sh
source "$HOME/.local/share/flutter-offline-3.44.8/env.sh"
```

To install only Flutter and its caches because native prerequisites are already present:

```bash
./install.sh --skip-native
```

## Verify without network

```bash
$HOME/.local/share/flutter-offline-3.44.8/verify-offline.sh
```

## Create a new Linux desktop app offline

```bash
$HOME/.local/share/flutter-offline-3.44.8/new-app.sh ~/projects/my_app my_app
```

The included pub cache cannot contain every package on pub.dev. Projects using additional third-party packages must cache those exact package versions before going offline.
README

cat > /out/kit-meta/MANIFEST.json <<MANIFEST
{
  "kit": "flutter-linux-desktop-offline",
  "target_os": "Debian GNU/Linux 13 (trixie)",
  "target_arch": "amd64/x86_64",
  "flutter_version": "$FLUTTER_VERSION",
  "flutter_commit": "058e0af2c2b57e369d905a03ac9748b0ebf543c6",
  "dart_version": "$DART_VERSION",
  "flutter_archive_sha256": "$FLUTTER_SHA256",
  "linux_desktop_precached": true,
  "offline_build_verified": true
}
MANIFEST

# Split large compressed payloads so every downloadable file stays manageable.
for archive in /out/*.tar.zst; do
  split --bytes=220M --numeric-suffixes=0 --suffix-length=3 \
    "$archive" "$archive.part-"
  rm -f "$archive"
done

(
  cd /out
  find . -maxdepth 1 -type f -name '*.part-*' -printf '%P\n' | sort | xargs sha256sum
) > /out/kit-meta/PAYLOAD_SHA256SUMS

(
  cd /out/kit-meta
  sha256sum env.sh install.sh verify-offline.sh new-app.sh README.md MANIFEST.json PAYLOAD_SHA256SUMS \
    > META_SHA256SUMS
  tar --create --zstd --file /out/flutter-offline-kit-meta.tar.zst .
)

find /out -maxdepth 1 -type f -printf '%f\t%s bytes\n' | sort > /out/OUTPUT_FILES.txt
cat /out/OUTPUT_FILES.txt
CONTAINER

printf 'Built files in %s\n' "$OUTPUT_DIR"
