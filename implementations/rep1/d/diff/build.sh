#!/bin/sh
# Build the mdiff command-line tool (bin/mdiff). Works from any directory.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --quiet
