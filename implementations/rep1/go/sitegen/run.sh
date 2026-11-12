#!/bin/sh
# Run sitegen: run.sh <input directory> <output directory>
exec "$(dirname "$0")/bin/sitegen" "$@"
