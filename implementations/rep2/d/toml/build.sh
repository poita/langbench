#!/bin/sh
# Build the toml CLI (release mode, LDC). Works from any current directory.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 -q
