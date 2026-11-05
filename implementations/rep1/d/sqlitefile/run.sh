#!/bin/sh
# Usage: run.sh <input dir> <output dir>
exec "$(dirname "$0")/sqlitefile" "$@"
