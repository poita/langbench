#!/bin/sh
# Run the kiln tool: run.sh <input dir> <output dir>. Works from any directory.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/kiln" "$@"
