#!/bin/sh
# Run the tomlcodec CLI: mode line + document on stdin, result on stdout.
here=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$here/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m tomlcodec "$@"
