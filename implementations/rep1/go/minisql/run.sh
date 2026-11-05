#!/bin/sh
# Run the minisql CLI: SQL script on stdin, query results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/minisql" "$@"
