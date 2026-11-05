#!/bin/sh
# Build the interpreter: produces bin/scheme.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --config=cli -q
