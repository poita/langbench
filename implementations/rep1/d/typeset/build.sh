#!/bin/sh
# Build the typeset command-line tool (works from any directory).
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 -q
