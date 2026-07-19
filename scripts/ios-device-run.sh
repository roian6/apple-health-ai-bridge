#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT_DIR/scripts/ios-device-build.sh"
"$ROOT_DIR/scripts/ios-device-install.sh"
"$ROOT_DIR/scripts/ios-device-launch.sh"
