#!/bin/sh
# Build the mime command-line tool (bin/mime).
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --quiet
