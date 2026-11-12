#!/bin/sh
# Run depresolve: reads the problem on stdin, writes the resolution to stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m depresolve "$@"
