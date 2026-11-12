#!/bin/sh
# Run the inflate CLI: hex DEFLATE stream on stdin, hex output on stdout.
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m inflate "$@"
