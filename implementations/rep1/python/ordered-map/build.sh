#!/bin/sh
# Nothing to compile: byte-compile the package as a syntax check.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$DIR/src"
