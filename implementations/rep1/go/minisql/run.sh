#!/bin/sh
# Run the minisql CLI: SQL script on stdin, results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/minisql" "$@"
