#!/bin/sh
# Run the CLI: reads the batch on stdin, writes results to stdout.
cd "$(dirname "$0")"
exec "$(cabal list-bin -v0 exe:regex-backtrack)" "$@"
