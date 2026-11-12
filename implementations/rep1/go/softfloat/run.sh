#!/bin/sh
# Runs the softfloat CLI: operations on stdin, results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/softfloat" "$@"
