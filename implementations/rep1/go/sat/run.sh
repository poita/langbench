#!/bin/sh
# Run the sat command-line tool (stdin -> stdout).
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/sat" "$@"
