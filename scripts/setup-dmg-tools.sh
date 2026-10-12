#!/bin/bash
# Packaging tools are isolated from the app and system Python.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="$ROOT/.build/dmg-tools"
/usr/bin/python3 -m venv "$ENV"
"$ENV/bin/python3" -m pip install --disable-pip-version-check --only-binary=:all: \
  --require-hashes -r "$ROOT/scripts/requirements-dmg.txt"
