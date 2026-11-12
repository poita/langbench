#!/bin/sh
# Build step: the project is pure Python, so "building" means byte-compiling
# the sources (which also surfaces syntax errors early).
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$DIR/src"
