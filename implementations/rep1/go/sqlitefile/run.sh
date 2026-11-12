#!/bin/sh
# Run the sqlitefile command: run.sh <input directory> <output directory>
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/sqlitefile" "$@"
