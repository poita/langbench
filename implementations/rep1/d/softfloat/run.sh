#!/bin/sh
# Run the softfloat CLI: reads operations on stdin, writes results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/softfloat" "$@"
