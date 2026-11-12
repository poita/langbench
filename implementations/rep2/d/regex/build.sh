#!/bin/sh
# Build the regex CLI (release mode, LDC). Works from any directory.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --quiet
