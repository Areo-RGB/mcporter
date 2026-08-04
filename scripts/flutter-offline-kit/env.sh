#!/usr/bin/env bash
_KIT_PREFIX="${FLUTTER_OFFLINE_PREFIX:-$HOME/.local/share/flutter-offline-3.44.8}"
export FLUTTER_ROOT="$_KIT_PREFIX/flutter"
export PUB_CACHE="$_KIT_PREFIX/flutter-pub-cache"
export PATH="$FLUTTER_ROOT/bin:$FLUTTER_ROOT/bin/cache/dart-sdk/bin:$PATH"
export FLUTTER_SUPPRESS_ANALYTICS=true
export CC=clang
export CXX=clang++
export LDFLAGS="-fuse-ld=lld -Wl,--no-as-needed"
export PKG_CONFIG_PATH="/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
unset _KIT_PREFIX
