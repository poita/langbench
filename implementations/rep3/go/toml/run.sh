#!/bin/sh
# Runs the toml tool: reads stdin, writes stdout. Works from any directory.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/toml" "$@"
