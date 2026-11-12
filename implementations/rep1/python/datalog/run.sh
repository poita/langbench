#!/bin/sh
# Run the datalog CLI: program on stdin, answers on stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m datalog "$@"
