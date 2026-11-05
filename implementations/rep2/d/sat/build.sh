#!/bin/sh
# Build the sat CLI (bin/sat-cli) with dub + LDC. Works from any directory.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --config=cli 1>&2
