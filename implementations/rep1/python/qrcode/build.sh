#!/bin/sh
# Build step: the project is pure Python, so "building" byte-compiles the
# package (which also fails fast on syntax errors). Works from any directory.
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
exec python3 -m compileall -q "$DIR/src"
