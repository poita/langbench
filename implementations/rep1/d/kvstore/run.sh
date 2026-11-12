#!/bin/sh
# Run the Tessera tool: run.sh <input dir> <output dir>
exec "$(dirname "$0")/bin/tessera" "$@"
