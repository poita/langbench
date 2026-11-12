#!/bin/sh
# Build the project. Python is interpreted, so this only byte-compiles the
# sources (standard optimisation settings) to catch syntax errors early.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$DIR/src"
