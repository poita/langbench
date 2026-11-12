#!/bin/sh
# Runs the built chess-perft command: queries on stdin, results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/chess-perft" "$@"
