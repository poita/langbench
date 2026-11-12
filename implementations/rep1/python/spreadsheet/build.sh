#!/bin/sh
# Build the project: byte-compile the package (fails on any syntax error).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$DIR/src"
