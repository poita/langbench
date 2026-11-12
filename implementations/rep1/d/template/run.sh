#!/bin/sh
# Run the jinjalite command-line tool: stdin -> stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/jinjalite" "$@"
