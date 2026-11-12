#!/bin/sh
# Build step: the project is pure Python, so "building" byte-compiles the
# sources (and fails early on any syntax error).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$DIR/src"
