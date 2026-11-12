#!/bin/sh
# Run the tessera tool: run.sh <input dir> <output dir>
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/tessera" "$@"
