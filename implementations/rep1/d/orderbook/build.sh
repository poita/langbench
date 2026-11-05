#!/bin/sh
# Build the orderbook CLI (release, LDC).
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --quiet
