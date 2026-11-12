#!/bin/sh
# Byte-compile the package (the project is pure Python; there is nothing else
# to build).  Works from any directory.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$DIR/src"
