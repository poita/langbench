#!/bin/sh
# Byte-compile the package (standard optimisation level, i.e. no -O).
# Pure Python: there is nothing else to build.
here=$(cd "$(dirname "$0")" && pwd) || exit 1
python3 -m compileall -q "$here/src" || true
exit 0
