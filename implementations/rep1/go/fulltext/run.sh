#!/bin/sh
# Run the fulltext tool: run.sh <input directory> <output directory>
exec "$(cd "$(dirname "$0")" && pwd)/bin/fulltext" "$@"
