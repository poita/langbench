#!/bin/sh
# Build the linalg command-line tool (bin/linalg) with dub + LDC.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --config=cli -q
