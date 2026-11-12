#!/bin/sh
# Run the orderbook CLI: commands on stdin, events on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
exec "$(cabal list-bin exe:orderbook 2>/dev/null)" "$@"
