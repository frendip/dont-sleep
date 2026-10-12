#!/bin/bash
# Automated tests use injected power backends and temporary files only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
/usr/bin/swift test
/usr/bin/python3 -m unittest discover -s poc/tests
/usr/bin/python3 -m unittest discover -s scripts/tests
for script in scripts/*.sh; do /bin/bash -n "$script"; done
/usr/bin/plutil -lint Resources/Info.plist Resources/launchd/*.plist
