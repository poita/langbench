#!/bin/sh
# Run the converter: Markdown on stdin, HTML on stdout. Works from any directory.
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m cmarkpy "$@"
