#!/bin/sh
# Run the datalog CLI: program on stdin, query answers on stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$dir/bin/datalog" ]; then
  exec "$dir/bin/datalog"
fi
cd "$dir" && exec "$(cabal list-bin -v0 exe:datalog)"
