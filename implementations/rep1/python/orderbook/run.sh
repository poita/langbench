#!/bin/sh
# Run the order book CLI: commands on stdin, events on stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m orderbook "$@"
