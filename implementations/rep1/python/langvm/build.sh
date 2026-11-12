#!/bin/sh
# Byte-compile the package so start-up is fast. There is no install step.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$DIR/src" >/dev/null
