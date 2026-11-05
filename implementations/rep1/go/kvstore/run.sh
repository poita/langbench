#!/bin/sh
# Run the kvstore tool: run.sh <input dir> <output dir>
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/kvstore" "$@"
