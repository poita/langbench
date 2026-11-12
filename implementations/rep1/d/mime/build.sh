#!/bin/sh
# Build the command-line tool (bin/mime) with LDC in release mode.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2
