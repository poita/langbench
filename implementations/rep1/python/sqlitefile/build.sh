#!/bin/sh
# Build step: sqlitefile is pure Python, so "building" means byte-compiling the
# sources (which also catches syntax errors early).
set -e
here=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$here/src"
