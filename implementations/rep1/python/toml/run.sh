#!/bin/sh
# Run the command-line tool: reads stdin, writes stdout. Works from any directory.
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m tomlcodec "$@"
