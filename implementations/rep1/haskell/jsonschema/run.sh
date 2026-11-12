#!/bin/sh
# Run the jsonschema CLI: request document on stdin, one verdict per line on stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$dir/bin/jsonschema" ]; then
  exec "$dir/bin/jsonschema" "$@"
fi
cd "$dir" && exec "$(cabal list-bin exe:jsonschema)" "$@"
