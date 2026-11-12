#!/bin/sh
# Run the inflate CLI: hex DEFLATE stream on stdin, hex result (or "error") on stdout.
cd "$(dirname "$0")" || exit 1
exec "$(cabal list-bin exe:inflate -v0)"
