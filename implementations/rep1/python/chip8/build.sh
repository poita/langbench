#!/bin/sh
# Build step: the project is pure Python, so just byte-compile the sources to
# catch syntax errors early.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
python3 -m compileall -q "$DIR/src"
