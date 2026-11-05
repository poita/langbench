#!/bin/sh
# Build the depresolve command-line tool (bin/depresolve).
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --config=cli
