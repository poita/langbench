#!/bin/sh
# Runs the orderbook CLI: commands on stdin, events on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/orderbook" "$@"
