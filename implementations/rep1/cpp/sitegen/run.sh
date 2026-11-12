#!/bin/sh
# Runs the sitegen CLI: run.sh <input directory> <output directory>
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/sitegen" "$@"
