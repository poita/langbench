#!/bin/sh
# Usage: run.sh <input directory> <output directory>
DIR=$(cd "$(dirname "$0")" && pwd)
exec "$DIR/bin/sitegen" "$@"
