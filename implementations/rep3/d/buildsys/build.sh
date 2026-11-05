#!/bin/sh
# Build the kiln command-line tool (bin/kiln). Works from any directory.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --quiet
