#!/bin/sh
# Build depresolve: byte-compile the package (standard optimisation level).
set -e
here=$(cd "$(dirname "$0")" && pwd)
exec python3 -m compileall -q "$here/src"
