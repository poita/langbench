#!/bin/sh
# Build the kiln command-line tool (release mode, LDC) inside this directory.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
dub build -b release --compiler=ldc2 --quiet
