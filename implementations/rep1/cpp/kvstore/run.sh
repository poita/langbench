#!/bin/sh
# Usage: run.sh <input dir> <output dir>
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/tessera-cli" "$@"
