#!/bin/sh
# Run chess-perft: queries on stdin, results on stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
exec "$DIR/bin/chess-perft" "$@"
