#!/bin/sh
# Run the typeset command: run.sh <input directory> <output directory>
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/typeset" "$@"
