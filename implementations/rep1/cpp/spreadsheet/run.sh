#!/bin/sh
# Run the command-line tool: commands on stdin, results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/ssheet" "$@"
