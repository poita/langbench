#!/bin/sh
# Run the mime command: run.sh <input path> <output dir>
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/mime" "$@"
