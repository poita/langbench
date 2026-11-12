#!/bin/sh
# Build the solver (release mode, LDC). Works from any current directory.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --quiet
