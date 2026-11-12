#!/bin/sh
# Run the orderbook CLI: commands on stdin, events on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/target/release/orderbook" "$@"
