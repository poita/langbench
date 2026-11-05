#!/bin/sh
# Runs the typeset tool: run.sh <input directory> <output directory>
# Font and pattern data are read from ./data relative to the current directory.
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/bin/typeset" "$@"
