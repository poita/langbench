#!/bin/sh
# Build step: the project is pure Python, so "building" byte-compiles the
# sources (validating that they parse). Works from any directory.
set -e
here=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$here/src"
