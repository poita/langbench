#!/bin/sh
# Run the spreadsheet CLI: commands on stdin, results on stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m spreadsheet "$@"
