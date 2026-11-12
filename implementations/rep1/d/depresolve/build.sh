#!/bin/sh
# Build the depresolve command-line tool (and library) with dub + LDC.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --quiet
