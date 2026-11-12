#!/bin/sh
# Runs the command-line tool: reads stdin, writes stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/toml" "$@"
