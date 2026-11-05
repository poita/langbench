#!/bin/sh
# Usage: run.sh <input directory> <output directory>
exec "$(dirname "$0")/kiln" "$@"
