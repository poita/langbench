#!/bin/sh
# Run the svgraster CLI: run.sh <input-dir> <output-dir>
exec "$(dirname "$0")/svgraster" "$@"
