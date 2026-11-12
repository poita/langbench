#!/bin/sh
# Run the sat executable: DIMACS CNF on stdin, answer on stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
cd "$dir" || exit 1
exec "$(cabal list-bin -v0 exe:sat)" "$@"
