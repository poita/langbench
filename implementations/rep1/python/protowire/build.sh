#!/bin/sh
# Nothing to build for a pure-Python project; byte-compile as a syntax check.
set -e
here=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$here/src"
