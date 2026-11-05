#!/usr/bin/env bash
# Build the jq command-line tool (bin/jq). Works from any directory.
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v ldc2 >/dev/null 2>&1 && [ -x "$HOME/dlang/ldc-1.41.0/bin/ldc2" ]; then
    export PATH="$HOME/dlang/ldc-1.41.0/bin:$PATH"
fi
exec dub build -b release --compiler=ldc2 --quiet
