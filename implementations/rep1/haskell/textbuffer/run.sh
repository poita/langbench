#!/bin/sh
# Run the textbuffer tool: reads a script on stdin, writes prints to stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$dir/bin/textbuffer" ]; then
  exec "$dir/bin/textbuffer" "$@"
fi
cd "$dir" && exec "$(cabal list-bin -v0 exe:textbuffer)" "$@"
