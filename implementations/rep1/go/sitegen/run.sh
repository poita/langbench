#!/bin/sh
# Run sitegen: run.sh <input directory> <output directory>
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/sitegen" "$@"
