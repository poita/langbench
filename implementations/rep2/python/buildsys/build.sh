#!/bin/sh
# Build Kiln.  The project is pure Python, so "building" byte-compiles the
# package (surfacing syntax errors early); nothing else is required to run it.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"
python3 -m compileall -q src
