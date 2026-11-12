#!/bin/sh
# Build step: the project is pure Python with no install step, so "building"
# means byte-compiling the sources, which surfaces any syntax error early.
set -e
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 -m compileall -q "$DIR/src"
