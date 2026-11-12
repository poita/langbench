#!/bin/sh
# Byte-compile the package (and check that it is syntactically valid).
# There is nothing else to build for a pure-Python project.
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$DIR/src"
