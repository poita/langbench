#!/bin/sh
# Run the bigint CLI: reads queries on stdin, writes results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/bigint" "$@"
