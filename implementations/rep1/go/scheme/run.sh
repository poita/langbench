#!/bin/sh
# Run the scheme CLI: program on stdin, output on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/scheme" "$@"
