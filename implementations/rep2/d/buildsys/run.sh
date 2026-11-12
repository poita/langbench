#!/bin/sh
# Usage: run.sh <input directory> <output directory>
HERE=$(cd "$(dirname "$0")" && pwd)
exec "$HERE/kiln" "$@"
