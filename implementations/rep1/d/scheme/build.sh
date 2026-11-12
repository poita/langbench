#!/bin/sh
# Build the scheme interpreter (release mode, LDC).
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --quiet
