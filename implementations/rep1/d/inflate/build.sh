#!/bin/sh
# Build the inflate command-line tool (release mode, LDC).
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --quiet
