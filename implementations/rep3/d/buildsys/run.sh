#!/bin/sh
# Run kiln: run.sh <input dir> <output dir>. Works from any directory.
exec "$(dirname "$0")/bin/kiln" "$@"
