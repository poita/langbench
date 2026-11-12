#!/bin/sh
# Run the orderbook CLI: commands on stdin, events on stdout.
exec "$(dirname "$0")/bin/orderbook" "$@"
