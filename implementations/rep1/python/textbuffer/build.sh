#!/bin/sh
# Build the project. Pure Python: byte-compile the package to catch syntax
# errors early (the interpreter's standard optimisation level is unchanged).
set -e
here=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$here/src" >/dev/null
