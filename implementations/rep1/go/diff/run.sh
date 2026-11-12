#!/bin/sh
# Run the diff tool: reads stdin, writes stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/diff" "$@"
