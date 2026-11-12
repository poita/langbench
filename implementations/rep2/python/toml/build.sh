#!/bin/sh
# Build the project: byte-compile the package (also a syntax check).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
exec python3 -m compileall -q "$here/src"
