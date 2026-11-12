#!/bin/sh
# Run the protowire CLI: reads a schema and requests on stdin, writes results to stdout.
here=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$here/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m protowire "$@"
