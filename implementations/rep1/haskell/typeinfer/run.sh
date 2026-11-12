#!/bin/sh
# Run the typeinfer CLI: program on stdin, types on stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$dir/dist/typeinfer" ]; then
  exec "$dir/dist/typeinfer" "$@"
fi
cd "$dir" && exec "$(cabal list-bin exe:typeinfer)" "$@"
