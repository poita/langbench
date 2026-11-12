#!/bin/sh
# Build the btregex command-line tool (bin/btregex) with dub + LDC.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
if ! command -v dub >/dev/null 2>&1 && [ -x "$HOME/dlang/ldc-1.41.0/bin/dub" ]; then
    PATH="$HOME/dlang/ldc-1.41.0/bin:$PATH"
    export PATH
fi
cd "$DIR"
exec dub build -b release --compiler=ldc2 -c cli --quiet
