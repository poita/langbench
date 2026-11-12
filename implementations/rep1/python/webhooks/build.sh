#!/bin/sh
# Build step: the project is pure Python, so "building" byte-compiles the
# sources (a syntax check) with the interpreter's default optimisation level.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
exec python3 -m compileall -q "$dir/src"
