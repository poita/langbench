#!/bin/sh
# Run the CLI: reads commands on stdin, writes results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$dir/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m webhooks "$@"
