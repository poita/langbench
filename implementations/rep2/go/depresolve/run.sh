#!/bin/sh
# Runs depresolve: reads the problem on stdin, writes the resolution on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/depresolve" "$@"
