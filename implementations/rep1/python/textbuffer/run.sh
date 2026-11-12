#!/bin/sh
# Run the textbuffer CLI: reads stdin, writes stdout.
here=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$here/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m textbuffer "$@"
