#!/bin/sh
# Usage: run.sh <input path> <output dir>
exec "$(dirname "$0")/bin/mime" "$@"
