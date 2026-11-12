#!/bin/sh
# Build the inflate-cli executable (bin/inflate-cli). Works from any directory.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 :cli
