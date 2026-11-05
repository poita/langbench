#!/bin/sh
# Run the protowire CLI: reads stdin, writes stdout. Works from any directory.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/protowire" "$@"
