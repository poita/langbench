#!/bin/sh
# Run the minisql CLI: SQL script on stdin, query results on stdout.
# Works from any directory.
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m minisql "$@"
