#!/bin/sh
# Build the depresolve command-line tool (release mode, LDC).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"
exec dub build -b release --compiler=ldc2 --quiet
