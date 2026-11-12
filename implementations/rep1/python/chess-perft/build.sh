#!/bin/sh
# Build step: byte-compile the package (standard, unoptimised settings).
# There is nothing else to build; the program is run straight from src/.
set -e
here=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$here/src"
