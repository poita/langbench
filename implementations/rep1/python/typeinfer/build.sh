#!/bin/sh
# Build typeinfer: there is nothing to link, so "building" byte-compiles the
# package (standard optimisation settings) to catch syntax errors early.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$DIR/src"
