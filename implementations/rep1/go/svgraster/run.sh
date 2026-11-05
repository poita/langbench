#!/bin/sh
# Usage: run.sh <input-dir> <output-dir>
DIR=$(cd "$(dirname "$0")" && pwd)
exec "$DIR/bin/svgraster" "$@"
