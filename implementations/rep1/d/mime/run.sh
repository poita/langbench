#!/bin/sh
# Run the mime CLI: run.sh <input mbox or directory> <output directory>
exec "$(dirname "$0")/bin/mime" "$@"
