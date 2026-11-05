#!/bin/sh
# Build the softfloat CLI (release mode, LDC).
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
exec dub build -b release --compiler=ldc2 --quiet
