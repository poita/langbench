#!/bin/sh
# Build the sat command-line tool (bin/sat) from any working directory.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --quiet
