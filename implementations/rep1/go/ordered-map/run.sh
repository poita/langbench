#!/bin/sh
# Run the ordered-map command-line tool (stdin -> stdout).
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/ordered-map" "$@"
