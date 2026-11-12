#!/bin/sh
# Run the fulltext tool: run.sh <input directory> <output directory>
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/fulltext" "$@"
