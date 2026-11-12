#!/bin/sh
# Build step: the project is pure Python, so just byte-compile the sources
# (this also catches syntax errors early).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$DIR/src"
