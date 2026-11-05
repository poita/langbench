#!/bin/sh
# Build the sat command-line tool (bin/sat). Works from any directory.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --quiet
