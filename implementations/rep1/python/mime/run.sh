#!/bin/sh
# Run the mimedump command-line tool: run.sh <input path> <output dir>
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m mimedump "$@"
