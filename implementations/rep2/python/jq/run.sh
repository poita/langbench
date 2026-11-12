#!/bin/sh
# Run the jq-subset interpreter: filter on line 1 of stdin, JSON document after.
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m jqlite "$@"
