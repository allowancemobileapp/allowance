#!/bin/bash
set -e

sudo apt-get update
sudo apt-get install -y xz-utils curl git

curl -LO https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.24.0-stable.tar.xz
tar -xf flutter_linux_3.24.0-stable.tar.xz

export PATH="$PATH:$(pwd)/flutter/bin"
flutter --version
