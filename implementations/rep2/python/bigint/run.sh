#!/bin/sh
# Run the CLI: queries on stdin, results on stdout. Works from any directory.
here=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$here/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m bigint "$@"
