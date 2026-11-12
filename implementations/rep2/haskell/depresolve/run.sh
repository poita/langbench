#!/bin/sh
# Run depresolve: reads the problem on stdin, writes the resolution to stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
exec "$(cd "$dir" && cabal list-bin exe:depresolve -v0)" "$@"
