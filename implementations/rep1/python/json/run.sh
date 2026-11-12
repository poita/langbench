#!/bin/sh
# Run the CLI: canonicalise the JSON document on stdin.
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m jsoncanon "$@"
