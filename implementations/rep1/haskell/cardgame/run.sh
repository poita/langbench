#!/bin/sh
# Run the cardgame CLI: reads a match file on stdin, writes the log to stdout.
# Works from any current directory (the binary is located relative to $0).
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/bin/cardgame"
if [ ! -x "$BIN" ]; then
  BIN="$(cd "$DIR" && cabal list-bin -v0 exe:cardgame)"
fi
exec "$BIN" "$@"
