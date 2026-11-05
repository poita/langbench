#!/bin/sh
# Run the typeset tool: run.sh <input directory> <output directory>.
# The current directory is left alone (the tool reads ./data from it).
exec "$(dirname "$0")/bin/typeset" "$@"
