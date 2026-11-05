#!/bin/sh
# Run the chess-perft CLI: queries on stdin, answers on stdout.
exec "$(dirname "$0")/chess-perft" "$@"
