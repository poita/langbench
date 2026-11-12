#!/bin/sh
# Byte-compile the package (Python needs no real build step).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$DIR/src"
