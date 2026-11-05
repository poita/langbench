#!/bin/sh
# Run the chess-perft tool: queries on stdin, results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/chess-perft" "$@"
