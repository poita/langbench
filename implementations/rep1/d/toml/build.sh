#!/bin/sh
# Builds the project (release mode, LDC). Works from any directory.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --quiet
