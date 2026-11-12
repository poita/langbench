#!/bin/sh
# Build depresolve. The project is pure Python, so "building" byte-compiles
# the package (with the interpreter's standard optimisation settings) to catch
# syntax errors early. Works from any current directory.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$DIR/src"
