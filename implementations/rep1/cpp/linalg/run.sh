#!/bin/sh
# Usage: run.sh <input directory> <output directory>
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/linalg_cli" "$@"
