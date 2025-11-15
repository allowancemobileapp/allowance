#!/bin/bash

# --- Install dependencies ---
apt-get update && apt-get install -y curl unzip xz-utils git

# --- Download Flutter 3.24.3 (supports Dart 3.5) ---
curl -O https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.24.3-stable.tar.xz

# --- Extract Flutter ---
tar xf flutter_linux_3.24.3-stable.tar.xz

# --- Add Flutter to PATH ---
export PATH="$PATH:`pwd`/flutter/bin"

# --- Allow git safe directory ---
git config --global --add safe.directory /vercel/path0/flutter

# --- Enable web ---
flutter config --enable-web

# --- Get dependencies ---
flutter pub get

# --- Build ---
flutter build web --release
