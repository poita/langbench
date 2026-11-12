#!/bin/sh
# Run typeinfer: reads a program on stdin, writes one line per declaration.
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m typeinfer "$@"
