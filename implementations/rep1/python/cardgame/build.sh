#!/bin/sh
# Build step: the project is pure Python, so this only byte-compiles the
# sources (which also catches syntax errors early).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
python3 -m compileall -q "$DIR/src"
