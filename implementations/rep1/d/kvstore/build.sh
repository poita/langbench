#!/bin/sh
# Build the Tessera command-line tool (bin/tessera) from any directory.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --quiet
