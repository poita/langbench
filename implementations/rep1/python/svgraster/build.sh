#!/bin/sh
# Build step: byte-compile the package (there is nothing else to build).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONDONTWRITEBYTECODE= python3 -m compileall -q "$DIR/src"
