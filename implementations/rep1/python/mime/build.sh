#!/bin/sh
# Build the project. The package is pure Python, so "building" means
# byte-compiling the sources (which also catches syntax errors early).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
exec python3 -m compileall -q "$DIR/src"
