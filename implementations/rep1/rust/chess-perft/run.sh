#!/bin/sh
# Run chess-perft: queries on stdin, results on stdout. Works from any directory.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/target/release/chess-perft" "$@"
