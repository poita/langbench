#!/bin/sh
# Run the typeset command-line tool: run.sh <input directory> <output directory>
# The tool reads fonts and hyphenation patterns from ./data relative to the
# current directory.  Works from any current directory.
DIR=$(cd "$(dirname "$0")" && pwd)
if [ -x "$DIR/bin/typeset" ]; then
  exec "$DIR/bin/typeset" "$@"
fi
cd "$DIR" && BIN=$(cabal list-bin exe:typeset) || exit 1
cd - >/dev/null
exec "$BIN" "$@"
