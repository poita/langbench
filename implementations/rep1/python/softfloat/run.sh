#!/bin/sh
# Run the softfloat CLI: reads operations on stdin, writes results to stdout.
here=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$here/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m softfloat "$@"
