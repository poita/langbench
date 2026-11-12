#!/bin/sh
# Run the chess-perft CLI: queries on stdin, results on stdout.
here=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$here/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m chess_perft "$@"
