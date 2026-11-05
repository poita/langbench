#!/bin/sh
# Run the rrule command-line tool: stdin -> stdout. Works from any directory.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/rrule" "$@"
