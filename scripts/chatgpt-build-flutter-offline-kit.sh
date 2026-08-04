#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$(realpath -m "${1:-flutter-offline-output}")"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

FLUTTER_VERSION="3.44.8"
DART_VERSION="3.12.2"
FLUTTER_ARCHIVE="flutter_linux_3.44.8-stable.tar.xz"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${FLUTTER_ARCHIVE}"
FLUTTER_SHA256="672089e001571a9fbb209a495c583580c0c6c73ef98999264ba07fa93ace332d"
export FLUTTER_VERSION DART_VERSION FLUTTER_ARCHIVE FLUTTER_URL FLUTTER_SHA256

docker run --rm -i --platform linux/amd64 \
  -e FLUTTER_VERSION -e DART_VERSION -e FLUTTER_ARCHIVE -e FLUTTER_URL -e FLUTTER_SHA256 \
  -v "$OUTPUT_DIR:/out" \
  -v "$SCRIPT_DIR/flutter-offline-kit:/kit-meta-src:ro" \
  debian:13-slim bash -s <<'CONTAINER'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export CI=true
export FLUTTER_SUPPRESS_ANALYTICS=true
mkdir -p /out/native-debs/partial /work /opt/flutter-pub-cache /tmp/flutter-home

packages=(
  ca-certificates curl file git unzip xz-utils zip zstd
  clang lld cmake ninja-build pkg-config libgtk-3-dev libstdc++-14-dev libglu1-mesa
  libsecret-1-dev libayatana-appindicator3-dev libsqlite3-dev libnotify-dev
)
apt-get update
apt-get -y -o Dir::Cache::archives=/out/native-debs --download-only install --no-install-recommends "${packages[@]}"
apt-get -y -o Dir::Cache::archives=/out/native-debs --no-download install --no-install-recommends "${packages[@]}"
dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > /out/DEBIAN13_INSTALLED_PACKAGE_MANIFEST.tsv

cd /tmp
curl --fail --location --retry 5 --retry-delay 3 --output "$FLUTTER_ARCHIVE" "$FLUTTER_URL"
printf '%s  %s\n' "$FLUTTER_SHA256" "$FLUTTER_ARCHIVE" | sha256sum --check -
tar --extract --xz --file "$FLUTTER_ARCHIVE" --directory /opt --no-same-owner
chown -R root:root /opt/flutter
git config --global --add safe.directory /opt/flutter

export HOME=/tmp/flutter-home
export PUB_CACHE=/opt/flutter-pub-cache
export PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:$PATH"
export CC=clang
export CXX=clang++
export LDFLAGS="-fuse-ld=lld -Wl,--no-as-needed"
export PKG_CONFIG_PATH="/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig"

flutter --disable-analytics || true
dart --disable-analytics || true
flutter config --enable-linux-desktop --no-enable-android --no-enable-ios --no-enable-web --no-enable-macos-desktop --no-enable-windows-desktop
flutter precache --linux
flutter --version > /out/FLUTTER_VERSION.txt
flutter doctor -v | tee /out/FLUTTER_DOCTOR.txt

cd /work
flutter create --platforms=linux --project-name offline_starter offline_starter
cd offline_starter
flutter pub get
flutter build linux --release --no-pub
mkdir -p /work/prebuilt-smoke-app
cp -a build/linux/x64/release/bundle/. /work/prebuilt-smoke-app/

cd /work
flutter create --platforms=linux --project-name desktop_toolbox desktop_toolbox
cd desktop_toolbox
flutter pub add file_selector path_provider shared_preferences url_launcher
flutter pub get
flutter build linux --release --no-pub

# Prove both projects resolve and build with no usable HTTP path.
export FLUTTER_STORAGE_BASE_URL="http://127.0.0.1:9"
export HTTP_PROXY="http://127.0.0.1:9"
export HTTPS_PROXY="http://127.0.0.1:9"
export http_proxy="$HTTP_PROXY"
export https_proxy="$HTTPS_PROXY"
for project in offline_starter desktop_toolbox; do
  cd "/work/$project"
  flutter pub get --offline
  rm -rf build
  flutter build linux --release --no-pub
  printf '%s offline release build succeeded.\n' "$project"
done | tee /out/OFFLINE_VERIFICATION.txt
cp -a /work/offline_starter/build/linux/x64/release/bundle/. /work/prebuilt-smoke-app/

rm -rf /work/offline_starter/build /work/desktop_toolbox/build
find /out/native-debs -type f ! -name '*.deb' -delete
mkdir -p /out/kit-meta
cp /kit-meta-src/env.sh /kit-meta-src/install.sh /kit-meta-src/verify-offline.sh /kit-meta-src/new-app.sh /kit-meta-src/README.md /out/kit-meta/
chmod 0755 /out/kit-meta/*.sh
cat > /out/kit-meta/MANIFEST.json <<MANIFEST
{
  "kit": "flutter-linux-desktop-offline",
  "target_os": "Debian GNU/Linux 13 (trixie)",
  "target_arch": "amd64/x86_64",
  "flutter_version": "$FLUTTER_VERSION",
  "flutter_commit": "058e0af2c2b57e369d905a03ac9748b0ebf543c6",
  "dart_version": "$DART_VERSION",
  "flutter_archive_sha256": "$FLUTTER_SHA256",
  "linker": "LLVM lld with --no-as-needed",
  "linux_desktop_precached": true,
  "basic_offline_build_verified": true,
  "plugin_offline_build_verified": true
}
MANIFEST

export ZSTD_CLEVEL=6
export ZSTD_NBTHREADS=0
tar --create --zstd --file "/out/flutter-sdk-${FLUTTER_VERSION}-linux-x64-debian13.tar.zst" --directory /opt flutter
tar --create --zstd --file "/out/flutter-pub-cache-${FLUTTER_VERSION}-desktop.tar.zst" --directory /opt flutter-pub-cache
tar --create --zstd --file "/out/flutter-desktop-samples-${FLUTTER_VERSION}.tar.zst" --directory /work offline_starter desktop_toolbox prebuilt-smoke-app
tar --create --zstd --file "/out/flutter-native-debs-debian13-amd64.tar.zst" --directory /out/native-debs .

for archive in /out/*.tar.zst; do
  split --bytes=220M --numeric-suffixes=0 --suffix-length=3 "$archive" "$archive.part-"
  rm -f "$archive"
done
(
  cd /out
  find . -maxdepth 1 -type f -name '*.part-*' -printf '%P\n' | sort | xargs sha256sum
) > /out/kit-meta/PAYLOAD_SHA256SUMS
(
  cd /out/kit-meta
  sha256sum env.sh install.sh verify-offline.sh new-app.sh README.md MANIFEST.json PAYLOAD_SHA256SUMS > META_SHA256SUMS
  tar --create --zstd --file /out/flutter-offline-kit-meta.tar.zst .
)
find /out -maxdepth 1 -type f -printf '%f\t%s bytes\n' | sort > /out/OUTPUT_FILES.txt
cat /out/OUTPUT_FILES.txt
CONTAINER

printf 'Built files in %s\n' "$OUTPUT_DIR"
