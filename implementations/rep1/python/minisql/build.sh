#!/bin/sh
# Build minisql. The project is pure Python, so "building" means
# byte-compiling the package (with the interpreter's default optimisation
# settings) to catch syntax errors early. Works from any directory.
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$DIR/src"
