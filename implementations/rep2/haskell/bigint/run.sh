#!/bin/sh
# Run the bigint CLI: queries on stdin, results on stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$dir/bin/bigint" ]; then
  exec "$dir/bin/bigint"
fi
cd "$dir" && exec "$(cabal list-bin exe:bigint)"
