#!/usr/bin/env bash
# Build the project (release mode, LDC).
set -euo pipefail
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --quiet
