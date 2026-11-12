#!/bin/sh
# Run the CLI: reads the problem on stdin, writes results to stdout.
here=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$here/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m btregex "$@"
