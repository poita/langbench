#!/bin/sh
# Run the jq-hs CLI: filter on the first line of stdin, JSON document after it.
dir="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$dir/bin/jq-hs" ]; then
  exec "$dir/bin/jq-hs" "$@"
fi
cd "$dir" && exec "$(cabal list-bin -v0 exe:jq-hs)" "$@"
