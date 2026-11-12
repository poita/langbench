#!/bin/sh
# Run kiln: run.sh <input directory> <output directory>. Works from any directory.
exec "$(dirname "$0")/bin/kiln" "$@"
