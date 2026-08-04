# Flutter Linux desktop offline kit

Target: Debian 13 (trixie), amd64/x86_64.

Included:

- Flutter 3.44.8 stable and Dart 3.12.2
- Linux desktop engine artifacts already precached
- Offline pub cache for a starter project and the official desktop packages `file_selector`, `path_provider`, `shared_preferences`, and `url_launcher`
- Debian 13 native development `.deb` packages, including Clang, LLD, CMake, Ninja, pkg-config, GTK 3 headers, and the C++ toolchain
- A minimal starter source tree, a desktop-toolbox source tree, and a prebuilt smoke-test application
- Installer, environment setup, offline verification, checksums, and a new-project helper

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

The included cache cannot contain every package on pub.dev. Projects using additional third-party packages must cache those exact package versions before going offline.
