#!/bin/sh
# Build jqlite: pure Python, so "building" only byte-compiles the sources.
set -e
here=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$here/src"
