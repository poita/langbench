#!/bin/sh
# Run the gitrepo CLI: run.sh <input path> <output dir>
exec "$(dirname "$0")/bin/gitrepo" "$@"
