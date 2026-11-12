#!/bin/sh
# Build step: byte-compile the package (standard optimisation settings).
set -e
here=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$here/src"
