#!/bin/sh
# Run the cardgame CLI: reads a match file on stdin, writes the log on stdout.
# Works from any directory (the working directory is preserved, because the
# match file's relative CARDS path is resolved against it).
exec "$(dirname "$0")/target/release/cardgame" "$@"
