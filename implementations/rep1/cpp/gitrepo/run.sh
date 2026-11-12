#!/bin/sh
# Usage: run.sh <input path> <output dir>
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/gitrepo" "$@"
