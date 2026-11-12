#!/bin/sh
# Run langvm: reads a Vellum module stream on stdin, writes the result to stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m langvm "$@"
