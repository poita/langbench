#!/bin/sh
# Run the CLI: reads commands on stdin, writes results to stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/ordered-map" "$@"
