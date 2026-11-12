#!/bin/sh
# Build step: the project is pure Python, so "building" byte-compiles the
# package (which also catches syntax errors early).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$DIR/src"
