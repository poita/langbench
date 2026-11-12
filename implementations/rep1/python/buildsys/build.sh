#!/bin/sh
# Build step for the Kiln project.
#
# Kiln is pure Python, so there is nothing to compile: this byte-compiles the
# package (standard optimisation settings) to catch syntax errors early and to
# make the first run faster.  A wheel can be produced with `python3 -m build`
# where the `build` package is available.
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
exec python3 -m compileall -q "$DIR/src"
