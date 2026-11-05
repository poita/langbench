#!/bin/sh
# Build the regex project (release mode, LDC).
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --quiet
