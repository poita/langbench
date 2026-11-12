#!/bin/sh
# Run the depresolve CLI: reads the problem on stdin, writes the resolution to stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/depresolve" "$@"
