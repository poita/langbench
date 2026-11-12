#!/bin/sh
# Run the mime tool: run.sh <input path> <output dir>. Works from any current directory.
exec "$(dirname "$0")/target/release/mime" "$@"
