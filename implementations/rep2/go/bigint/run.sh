#!/bin/sh
# Run the bigint tool: queries on stdin, results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/bigint" "$@"
