#!/bin/sh
# Build the softfloat command-line tool (bin/softfloat).
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --quiet
