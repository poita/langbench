#!/bin/sh
# Run the Spiremark engine: match file on stdin, log on stdout.
DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m cardgame "$@"
