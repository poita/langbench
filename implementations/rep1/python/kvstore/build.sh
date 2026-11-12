#!/bin/sh
# Build step: byte-compile the package (the project has no compiled parts).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
exec python3 -m compileall -q "$DIR/src"
