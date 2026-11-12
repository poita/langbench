#!/bin/sh
# Run the order book CLI: commands on stdin, events on stdout.
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/build/orderbook" "$@"
