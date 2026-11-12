#!/bin/sh
# Build the project: byte-compile the sources (standard optimisation level).
# Python is interpreted, so this is only a syntax check plus a warm cache.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
exec python3 -m compileall -q "$DIR/src"
