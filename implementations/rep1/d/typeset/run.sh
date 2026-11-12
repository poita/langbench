#!/bin/sh
# Run the typeset CLI: run.sh <input dir> <output dir>
# The font/pattern data is read from ./data relative to the current directory.
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/build/typeset" "$@"
