#!/bin/sh
# Build step: the project is pure Python, so just byte-compile the sources
# to catch syntax errors early. Works from any current directory.
set -e
here=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$here/src"
