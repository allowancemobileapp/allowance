#!/bin/bash

# Install Flutter
curl -O https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.24.3-stable.tar.xz
tar xf flutter_linux_3.24.3-stable.tar.xz
export PATH="$PWD/flutter/bin:$PATH"

# Enable web
flutter config --enable-web

# Get packages
flutter pub get

# Build web
flutter build web --release
