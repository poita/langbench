#!/bin/sh
# Run the typesetter: run.sh <input directory> <output directory>
# Works from any current directory; font and pattern data are read from
# ./data relative to the caller's working directory (see README).
exec "$(dirname "$0")/target/release/typeset" "$@"
