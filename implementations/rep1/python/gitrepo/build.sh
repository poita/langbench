#!/bin/sh
# Build gitrepo. The project is pure Python, so "building" byte-compiles the
# package (standard optimisation settings: no -O flags) to catch syntax errors.
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
python3 -m compileall -q src
