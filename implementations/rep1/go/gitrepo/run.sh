#!/bin/sh
# Run the gitrepo tool: run.sh <input path> <output dir>
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/gitrepo" "$@"
