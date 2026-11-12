#!/bin/sh
# Run the CLI: reads queries on stdin, writes results on stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m bigint "$@"
