#!/bin/sh
# Run the jsoncanon tool: reads a JSON document on stdin, writes its canonical
# form (or "invalid") on stdout. Works from any directory.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/jsoncanon" "$@"
