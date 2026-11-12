#!/bin/sh
# Build step. The project is pure Python with no install step, so "building"
# just byte-compiles the sources to catch syntax errors early.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$dir/src"
