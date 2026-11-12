#!/bin/sh
# Run the CLI: reads the batch format on stdin, writes results to stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/regex-backtrack" "$@"
