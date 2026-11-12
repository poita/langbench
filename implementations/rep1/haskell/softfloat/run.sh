#!/bin/sh
# Run the softfloat CLI: reads operations on stdin, writes results on stdout.
cd "$(dirname "$0")"
exec "$(cabal list-bin exe:softfloat -v0)"
