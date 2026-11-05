#!/bin/sh
# Run the diff command: stdin -> stdout. Works from any current directory.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/diff" "$@"
