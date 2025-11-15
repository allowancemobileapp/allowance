#!/bin/bash

# Install dependencies
apt-get update && apt-get install -y curl unzip xz-utils git

# Download Flutter SDK
curl -O https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.22.2-stable.tar.xz

# Extract Flutter
tar xf flutter_linux_3.22.2-stable.tar.xz

# Add Flutter to PATH
export PATH="$PATH:`pwd`/flutter/bin"

# Enable web
flutter config --enable-web

# Get packages
flutter pub get

# Build web release
flutter build web --release
