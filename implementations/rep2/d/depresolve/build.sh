#!/bin/sh
# Build the depresolve CLI (produces ./depresolve next to this script).
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --quiet
