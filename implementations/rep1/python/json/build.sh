#!/bin/sh
# Build the project: byte-compile the package (standard optimisation level).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$DIR/src"
