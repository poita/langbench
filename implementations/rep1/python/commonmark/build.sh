#!/bin/sh
# Build step: the project is pure Python, so this only byte-compiles the
# sources (which speeds up start-up). Works from any directory.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
exec python3 -m compileall -q "$DIR/src"
