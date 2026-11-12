#!/bin/sh
# Run depresolve: stdin -> stdout. Works from any current directory.
dir="$(cd "$(dirname "$0")" && pwd)"
cd "$dir"
exec "$(cabal list-bin exe:depresolve -v0)" "$@"
