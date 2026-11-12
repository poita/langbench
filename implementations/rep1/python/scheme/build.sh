#!/bin/sh
# Byte-compile the package (the project is pure Python, so this is optional).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$DIR/src"
