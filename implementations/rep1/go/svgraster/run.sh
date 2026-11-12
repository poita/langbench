#!/bin/sh
# Run svgraster: run.sh <input-dir> <output-dir>
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/svgraster" "$@"
