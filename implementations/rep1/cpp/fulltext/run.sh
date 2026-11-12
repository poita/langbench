#!/bin/sh
# Usage: run.sh <input directory> <output directory>
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/build/fulltext" "$@"
