#!/bin/sh
# Run the rrule command-line tool (stdin -> stdout).
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/rrule" "$@"
