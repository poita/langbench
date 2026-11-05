#!/bin/sh
# Run the orderbook CLI: reads commands on stdin, writes events to stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/orderbook" "$@"
