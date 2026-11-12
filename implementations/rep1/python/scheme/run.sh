#!/bin/sh
# Run the Scheme interpreter: program on stdin, output on stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m scheme_interp "$@"
