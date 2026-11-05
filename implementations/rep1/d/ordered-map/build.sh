#!/bin/sh
# Build the ordered-map CLI (release mode, LDC). Works from any directory.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --config=cli --quiet
