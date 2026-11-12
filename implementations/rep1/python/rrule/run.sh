#!/bin/sh
# Run the rrule command-line tool: reads rules on stdin, writes occurrences to stdout.
DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m rrule "$@"
